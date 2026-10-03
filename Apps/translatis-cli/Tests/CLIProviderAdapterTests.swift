import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisCowork
import IntatisKnowledge
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
import XCTest
@testable import TranslatisCLI

final class CLIProviderAdapterTests: XCTestCase {
    func testPermissionReviewerFallsBackToJSONModelNotEnvironmentMainOverride()
        async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "translatis-cli-reviewer-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translatis.json")
        try writeProviderConfig([
            "model": "primary/main-model",
            "provider": [
                "primary": provider(
                    baseURL: "https://primary.example.invalid/v1",
                    models: ["main-model": ["name": "Configured Main"]]),
                "runtime": provider(
                    baseURL: "https://runtime.example.invalid/v1",
                    models: ["runtime-model": ["name": "Runtime Main"]]),
            ],
        ], to: file)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: ["TRANSLATIS_MODEL": "runtime/runtime-model"])

        XCTAssertEqual(config.selectedProviderID, "runtime")
        XCTAssertEqual(config.model, "runtime-model")
        XCTAssertEqual(
            config.permissionReviewerModel,
            CLIProviderModelSelection(
                providerID: "primary",
                modelID: "main-model"))

        let providerConfig = config.providerConfig()
        let primary = try XCTUnwrap(
            config.providerRoutes.first { $0.id == "primary" })
        let runtime = try XCTUnwrap(
            config.providerRoutes.first { $0.id == "runtime" })
        XCTAssertEqual(
            providerConfig.models.agent,
            ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: runtime),
                model: ModelID(rawValue: "runtime-model")))
        XCTAssertEqual(
            providerConfig.models.reviewer,
            ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: primary),
                model: ModelID(rawValue: "main-model")))

        let profiles = try await CLIInferenceProfiles.load(
            config: config,
            fileURL: directory.appendingPathComponent("catalog.json"))
        XCTAssertEqual(profiles.defaultBinding.modelID.rawValue, "runtime-model")
        XCTAssertEqual(
            profiles.permissionReviewerBinding.modelID.rawValue,
            "main-model")
        XCTAssertNotEqual(
            profiles.defaultBinding,
            profiles.permissionReviewerBinding)
    }

    func testExplicitPermissionReviewerModelMustResolveCanonicalConfiguredModel()
        throws {
        let directory = try makeTemporaryDirectory(
            prefix: "translatis-cli-reviewer-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translatis.json")

        for invalidValue in ["luna/model", "reviewer/missing-model"] {
            try writeProviderConfig([
                "model": "main/main-model",
                "permission_reviewer_model": invalidValue,
                "provider": [
                    "main": provider(
                        baseURL: "https://main.example.invalid/v1",
                        models: ["main-model": ["name": "Main"]]),
                    "reviewer": provider(
                        baseURL: "https://reviewer.example.invalid/v1",
                        models: ["luna/model": ["name": "Luna"]]),
                ],
            ], to: file)

            XCTAssertThrowsError(try CLIConfig.load(
                configurationFileURL: file,
                environment: [:])) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "permission_reviewer_model"),
                    "unexpected error for \(invalidValue): \(error)")
            }
        }
    }

    func testMissingReviewerCannotInventAnUnavailableJSONDefaultModel()
        throws {
        let directory = try makeTemporaryDirectory(
            prefix: "translatis-cli-reviewer-missing-default")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translatis.json")
        let configuredProvider = provider(
            baseURL: "https://main.example.invalid/v1",
            models: ["configured-model": ["name": "Configured"]])

        for root in [
            [
                "provider": ["main": configuredProvider],
            ],
            [
                "model": "main/unknown-model",
                "provider": ["main": configuredProvider],
            ],
        ] {
            try writeProviderConfig(root, to: file)

            XCTAssertThrowsError(try CLIConfig.load(
                configurationFileURL: file,
                environment: [:])) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "permission_reviewer_model"),
                    "unexpected error: \(error)")
            }
        }
    }

    func testCoworkBootstrapKeepsConfiguredReviewerIndependentOfMainRebind()
        async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "translatis-cli-reviewer-runtime")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("translatis.json")
        try writeProviderConfig([
            "model": "main/main-model",
            "permission_reviewer_model": "reviewer/luna/model",
            "provider": [
                "main": provider(
                    baseURL: "https://main.example.invalid/v1",
                    models: [
                        "main-model": ["name": "Main"],
                        "rebound-model": ["name": "Rebound Main"],
                    ]),
                "reviewer": provider(
                    baseURL: "https://reviewer.example.invalid/v1",
                    models: ["luna/model": ["name": "Luna"]]),
            ],
        ], to: file)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        let profiles = try await CLIInferenceProfiles.load(
            config: config,
            fileURL: directory.appendingPathComponent("catalog.json"))
        let reviewerBinding = profiles.permissionReviewerBinding
        XCTAssertEqual(reviewerBinding.modelID.rawValue, "luna/model")
        let reboundBinding = try XCTUnwrap(profiles.option(
            routeID: "main",
            model: "rebound-model",
            variantID: nil)?.binding)

        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config),
            inferenceCatalogSnapshot: profiles.snapshot)
        let workspace = directory.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let log = try EventLog(
            session: SessionID(rawValue: "cli-reviewer-runtime"),
            fileURL: directory
                .appendingPathComponent("session", isDirectory: true)
                .appendingPathComponent("events.jsonl"))
        let orchestrator = try Orchestrator.runtime(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: profiles.bindings,
            requiresInferenceBindings: true,
            resolvedInferenceFor: { agent in
                guard let binding = agent.agentInferenceBinding else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return try await registry.agentInference(for: binding)
            })

        let bootstrap = await orchestrator.bootstrapFreshSession(
            main: Agent(
                name: Orchestrator.mainAgentID,
                workspaceRoot: workspace,
                model: profiles.defaultBinding.modelID,
                agentInferenceBinding: profiles.defaultBinding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: CoworkSessionSettings(
                sessionID: await log.sessionID,
                defaultModelID: profiles.defaultBinding.modelID.rawValue,
                defaultInferenceProfileBinding: profiles.defaultBinding,
                workspaces: [CoworkSessionWorkspace(
                    path: workspace.path,
                    agentName: Orchestrator.mainAgentID.rawValue,
                    isPrimary: true)]),
            permissionReviewerModel: reviewerBinding.modelID,
            permissionReviewerInferenceBinding: reviewerBinding)
        XCTAssertEqual(bootstrap, .attached(Orchestrator.mainAgentID))
        let agentsAfterBootstrap = await orchestrator.agentList()
        XCTAssertEqual(
            agentsAfterBootstrap.first(where: {
                $0.name == Orchestrator.automaticPermissionReviewerID
            })?.agentInferenceBinding,
            reviewerBinding)

        let rebindResult = await orchestrator.rebindAgentInferenceProfile(
            agentID: Orchestrator.mainAgentID,
            binding: reboundBinding,
            hostAuthorized: true)
        XCTAssertEqual(
            rebindResult,
            .rebound(Orchestrator.mainAgentID, reboundBinding))
        let agentsAfterRebind = await orchestrator.agentList()
        XCTAssertEqual(
            agentsAfterRebind.first(where: {
                $0.name == Orchestrator.mainAgentID
            })?.agentInferenceBinding,
            reboundBinding)
        XCTAssertEqual(
            agentsAfterRebind.first(where: {
                $0.name == Orchestrator.automaticPermissionReviewerID
            })?.agentInferenceBinding,
            reviewerBinding)

        let projection = CoworkProjection.build(from: await log.replay())
        XCTAssertEqual(
            projection.agentRoster[Orchestrator.automaticPermissionReviewerID]?
                .agentInferenceBinding,
            reviewerBinding)
        await orchestrator.cancelAll(reason: "test complete")
    }

    func testOpenRouterKnowledgeRoleModelsStayOutOfInferenceProfiles()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-openrouter-knowledge-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let file = directory.appendingPathComponent("translatis.json")
        let object: [String: Any] = [
            "model": "OpenRouter/chat-model",
            "embedding_model": "OpenRouter/google/gemini-embedding-2",
            "reranker_model": "OpenRouter/cohere/rerank-4-pro",
            "provider": [
                "OpenRouter": [
                    "npm": "@ai-sdk/openai-compatible",
                    "options": [
                        "baseURL": "https://openrouter.ai/api/v1",
                        "apiKey": "{env:OPENROUTER_API_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat"],
                        "google/gemini-embedding-2": [
                            "name": "Gemini Embedding 2",
                            "provider": [
                                "npm": "@openrouter/ai-sdk-provider",
                            ],
                            "options": ["dimensions": 1_536],
                        ],
                        "cohere/rerank-4-pro": [
                            "name": "Cohere Rerank 4 Pro",
                            "provider": [
                                "npm": "@openrouter/ai-sdk-provider",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        XCTAssertNil(cliKnowledgeToolsConfigurationNotice(config: config))
        let endpoint = try XCTUnwrap(config.providerConfig().endpoints.first)
        XCTAssertEqual(
            endpoint.requestAdapter(for: ModelID(
                rawValue: "google/gemini-embedding-2")),
            .openRouter)
        XCTAssertEqual(
            endpoint.requestAdapter(for: ModelID(
                rawValue: "cohere/rerank-4-pro")),
            .openRouter)
        let profiles = try await CLIInferenceProfiles.load(
            config: config,
            fileURL: directory.appendingPathComponent("catalog.json"))
        XCTAssertEqual(profiles.options.map(\.modelID.rawValue), ["chat-model"])
    }

    func testKnowledgeRoleOnlyRoutesComposeStrictToolsWithoutResolvingSecrets()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-knowledge-models-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let file = directory.appendingPathComponent("translatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "embedding_model": "embedding/BAAI/bge-m3",
            "reranker_model": "reranker/BAAI/bge-reranker-v2-m3",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                        "apiKey": "{env:TRANSLATIS_TEST_CHAT_KEY}",
                    ],
                    "models": ["chat-model": ["name": "Chat"]],
                ],
                "embedding": [
                    "npm": "translatis:siliconflow-v1",
                    "options": [
                        "baseURL": "https://embedding.example.invalid/v1",
                        "apiKey": "{env:TRANSLATIS_TEST_EMBEDDING_KEY}",
                    ],
                    "models": [String: Any](),
                ],
                "reranker": [
                    "npm": "translatis:cohere-v2",
                    "options": [
                        "baseURL": "https://reranker.example.invalid/v2",
                        "apiKey": "{env:TRANSLATIS_TEST_RERANKER_KEY}",
                    ],
                    "models": [String: Any](),
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        XCTAssertNil(cliKnowledgeToolsConfigurationNotice(config: config))
        let providerConfig = config.providerConfig()
        XCTAssertNotNil(providerConfig.models.embedding)
        XCTAssertNotNil(providerConfig.models.reranker)
        XCTAssertEqual(config.providerRoutes.count, 3)

        let registry = ProviderRegistry(
            config: providerConfig,
            resolver: CLIExactSecretResolver(config: config))
        let augmenter = try XCTUnwrap(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
        let capability = CapabilityLease(
            tools: augmenter.additionalCapabilities)
        let workspace = WorkspaceLease(
            rootPath: directory.path,
            access: .readWrite,
            deniedPatterns: [])
        let lease = try await augmenter.augment(
            HostToolRegistryAugmentationInput(
                sessionID: SessionID(rawValue: "cli-knowledge-test"),
                agentID: AgentID(rawValue: "cli"),
                taskID: nil,
                capabilityLease: capability,
                workspaceLease: workspace,
                baseRegistry: ToolRegistry(
                    registrations: [],
                    registryVersion: "cli-base/1")))
        XCTAssertNotNil(lease.registry.registration(named: "build_knowledge"))
        XCTAssertNotNil(lease.registry.registration(named: "search_knowledge"))
        let drained = await lease.close()
        XCTAssertTrue(drained)
    }

    func testKnowledgeRolesRejectImplicitSelectedProviderFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-invalid-knowledge-route-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("translatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "embedding_model": "BAAI/bge-m3",
            "reranker_model": "chat/reranker-model",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                    ],
                    "models": ["chat-model": ["name": "Chat"]],
                ],
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        XCTAssertThrowsError(try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains(
                "embedding_model must use the canonical provider/model shape"))
        }
    }

    func testUnsupportedRerankerAdapterIsNotAdvertisedAsReady() throws {
        let baseURL = try XCTUnwrap(URL(
            string: "https://knowledge.example.invalid/v1"))
        let route = CLIProviderRoute(
            id: "knowledge",
            displayName: "Knowledge",
            baseURL: baseURL,
            chatEndpoint: nil,
            wire: .openai,
            requestAdapter: .openAICompatible,
            credentialRef: .environment("KNOWLEDGE_TEST_KEY"),
            inlineSecret: nil,
            models: [
                CLIProviderModel(
                    id: "chat-model",
                    displayName: "Chat"),
            ])
        let config = CLIConfig(
            baseURL: baseURL,
            apiKey: "unused-test-value",
            model: "chat-model",
            wire: .openai,
            reasoningEffort: nil,
            mode: .code,
            includeUsage: false,
            maxSteps: 1,
            providerRoutes: [route],
            selectedProviderID: route.id,
            embeddingModel: CLIProviderModelSelection(
                providerID: route.id,
                modelID: "BAAI/bge-m3"),
            rerankerModel: CLIProviderModelSelection(
                providerID: route.id,
                modelID: "BAAI/bge-reranker-v2-m3"))
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))

        let notice = try XCTUnwrap(
            cliKnowledgeToolsConfigurationNotice(config: config))
        XCTAssertTrue(notice.contains("explicit translatis:siliconflow-v1"))
        XCTAssertNil(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
    }

    func testCLIExternalKnowledgeCreationTouchesOnlyExactLeaf() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-exact-knowledge-root-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let exact = parent.appendingPathComponent(
            "store",
            isDirectory: true)
        let created = try prepareCLIKnowledgeDirectory(
            exact,
            operation: .build)
        XCTAssertEqual(
            created.path,
            exact.resolvingSymlinksInPath().standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: exact.path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let missingParent = parent.appendingPathComponent(
            "missing",
            isDirectory: true)
        let nested = missingParent.appendingPathComponent(
            "store",
            isDirectory: true)
        XCTAssertThrowsError(try prepareCLIKnowledgeDirectory(
            nested,
            operation: .build))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: missingParent.path))
    }

    func testModernConfigRoutesDedicatedImageModelWithoutSelectingItForChat()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-image-model-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "translatis.json")
        let object: [String: Any] = [
            "model": "chat/chat-model",
            "image_model": "images/gpt-image-1",
            "provider": [
                "chat": [
                    "options": [
                        "baseURL": "https://chat.example.invalid/v1",
                        "apiKey": "{env:TRANSLATIS_TEST_CHAT_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat Model"],
                    ],
                ],
                "images": [
                    "options": [
                        "baseURL": "https://images.example.invalid/v1",
                        "apiKey": "{env:TRANSLATIS_TEST_IMAGE_KEY}",
                    ],
                    // The role-specific image model is intentionally absent
                    // from the inference model menu.
                    "models": [String: Any](),
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])
        let providerConfig = config.providerConfig()
        let imageRoute = try XCTUnwrap(
            config.providerRoutes.first { $0.id == "images" })

        XCTAssertEqual(config.model, "chat-model")
        XCTAssertEqual(
            providerConfig.models.imageGen,
            ModelRef(
                endpoint: CLIInferenceRouteIdentity.endpointID(route: imageRoute),
                model: ModelID(rawValue: "gpt-image-1")))
        XCTAssertFalse(
            imageRoute.models.contains { $0.id == "gpt-image-1" })
    }

    func testModernConfigWithoutImageModelHasNoHiddenFallback()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-no-image-model-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "translatis.json")
        let object: [String: Any] = [
            "model": "test/chat-model",
            "provider": [
                "test": [
                    "options": [
                        "baseURL": "https://example.invalid/v1",
                        "apiKey": "{env:TRANSLATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "chat-model": ["name": "Chat Model"],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [:])

        XCTAssertNil(config.providerConfig().models.imageGen)
        XCTAssertNil(config.providerConfig().models.embedding)
        XCTAssertNil(config.providerConfig().models.reranker)
        XCTAssertTrue(try XCTUnwrap(
            cliKnowledgeToolsConfigurationNotice(config: config))
            .contains("embedding_model and reranker_model"))
        let registry = ProviderRegistry(
            config: config.providerConfig(),
            resolver: CLIExactSecretResolver(config: config))
        XCTAssertNil(makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry))
    }

    func testModernConfigPreservesProviderAndModelNPMAdapters()
        throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-provider-adapter-\(UUID().uuidString)",
                isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "translatis.json")
        let object: [String: Any] = [
            "model": "gateway/compatible/model",
            "provider": [
                "gateway": [
                    "npm":
                        "@ai-sdk/openai-compatible",
                    "options": [
                        "baseURL":
                            "https://example.invalid/v1",
                        "apiKey":
                            "{env:TRANSLATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "compatible/model": [
                            "name":
                                "Compatible",
                            "options": [
                                "reasoningEffort":
                                    "low",
                                "provider": [
                                    "only": [
                                        "base",
                                    ],
                                    "require_parameters":
                                        false,
                                ],
                            ],
                            "variants": [
                                "strict": [
                                    "reasoningEffort":
                                        "high",
                                    "provider": [
                                        "only": [
                                            "deepseek",
                                        ],
                                        "allow_fallbacks":
                                            false,
                                        "require_parameters":
                                            true,
                                    ],
                                ],
                            ],
                        ],
                        "openrouter/model": [
                            "name":
                                "OpenRouter",
                            "provider": [
                                "npm":
                                    "@openrouter/ai-sdk-provider",
                            ],
                            "options": [
                                "reasoning": [
                                    "effort": "high",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)

        let config = try CLIConfig.load(
            configurationFileURL: file,
            environment: [
                "TRANSLATIS_REASONING":
                    "high",
            ])
        let route = try XCTUnwrap(
            config.providerRoutes.first)
        XCTAssertEqual(
            route.requestAdapter,
            .openAICompatible)
        XCTAssertNil(
            route.models.first {
                $0.id == "compatible/model"
            }?.requestAdapterOverride)
        XCTAssertEqual(
            route.models.first {
                $0.id == "openrouter/model"
            }?.requestAdapterOverride,
            .openRouter)

        let endpoint = try XCTUnwrap(
            config.providerConfig().endpoints.first)
        XCTAssertEqual(
            endpoint.requestAdapter,
            .openAICompatible)
        XCTAssertEqual(
            endpoint.requestAdapter(
                for: .init(
                    rawValue: "openrouter/model")),
            .openRouter)
        XCTAssertEqual(
            endpoint.requestOptions(
                for: .init(
                    rawValue: "compatible/model"))[
                    "provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "require_parameters":
                    .bool(true),
                "allow_fallbacks":
                    .bool(false),
            ]))
    }

    func testMissingProviderNPMUsesOpenCodeCompatibleDefault()
        throws {
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredProvider(nil),
            .openAICompatible)
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredProvider("").rawValue,
            "")
        XCTAssertEqual(
            ProviderRequestAdapter
                .configuredModelOverride("  ")?
                .rawValue,
            "  ")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        return directory
    }

    private func writeProviderConfig(
        _ object: [String: Any],
        to file: URL
    ) throws {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }

    private func provider(
        baseURL: String,
        models: [String: Any]
    ) -> [String: Any] {
        [
            "options": [
                "baseURL": baseURL,
                "apiKey": "test-key",
            ],
            "models": models,
        ]
    }
}
