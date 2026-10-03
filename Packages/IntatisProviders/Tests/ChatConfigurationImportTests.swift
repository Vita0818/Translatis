import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

final class ChatConfigurationImportTests: XCTestCase {
    func testImportsModernJSONCAndRedactsLiteralCredential() throws {
        let data = Data(
            #"""
            {
              // The selected model may itself contain a slash.
              "model": "gateway/openai/gpt-5.6-test",
              "enabled_providers": ["gateway",],
              "provider": {
                "gateway": {
                  "name": "Gateway",
                  "npm": "@openrouter/ai-sdk-provider",
                  "options": {
                    "baseURL": "https://gateway.example/v1",
                    "responsesEndpoint": "https://gateway.example/v1/responses",
                    "apiKey": "fixture-secret-value",
                  },
                  "models": {
                    "openai/gpt-5.6-test": {
                      "name": "Test Model",
                      "options": { "reasoning_effort": "high" },
                      "variants": {
                        "fast": { "reasoning_effort": "low" },
                      },
                    },
                  },
                },
              },
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            sourceURL: URL(fileURLWithPath: "/tmp/intatis.jsonc"),
            environment: [:])

        XCTAssertEqual(imported.selectedProviderID, "gateway")
        XCTAssertEqual(imported.selectedModelID, "openai/gpt-5.6-test")
        XCTAssertEqual(imported.providerCount, 1)
        XCTAssertEqual(imported.modelCount, 1)
        XCTAssertEqual(imported.providers[0].displayName, "Gateway")
        XCTAssertEqual(
            imported.providers[0].endpoint.responsesEndpoint?.absoluteString,
            "https://gateway.example/v1/responses")
        XCTAssertEqual(
            imported.providers[0].endpoint.requestOptions(
                for: ModelID(rawValue: "openai/gpt-5.6-test"))["reasoning_effort"],
            .string("high"))
        XCTAssertEqual(
            imported.providers[0].endpoint.requestAdapter,
            .openRouter)
        XCTAssertEqual(imported.literalSecretProviderIDs, ["gateway"])
        XCTAssertFalse(imported.description.contains("fixture-secret-value"))

        var migrated: [String: String] = [:]
        imported.forEachLiteralSecret { migrated[$0] = $1 }
        XCTAssertEqual(migrated, ["gateway": "fixture-secret-value"])
        XCTAssertEqual(
            imported.warnings,
            [.ignoredModelVariants(
                providerID: "gateway",
                modelID: "openai/gpt-5.6-test")])
    }

    func testImportsLegacyDirectCatalog() throws {
        let data = Data(
            #"""
            {
              "selectedProviderID": "local",
              "selectedModelID": "model-a",
              "providers": [
                {
                  "id": "local",
                  "displayName": "Local Server",
                  "baseURL": "http://127.0.0.1:8080/v1",
                  "chatEndpoint": "http://127.0.0.1:8080/v1/chat/completions",
                  "apiKeySource": { "type": "authFile", "value": "" },
                  "models": [
                    { "id": "model-a", "displayName": "Model A" }
                  ]
                }
              ]
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(data: data)

        XCTAssertEqual(imported.selectedProviderID, "local")
        XCTAssertEqual(imported.selectedModelID, "model-a")
        XCTAssertEqual(imported.providers[0].models[0].displayName, "Model A")
        XCTAssertEqual(
            imported.providers[0].endpoint.apiKeyRef,
            .authFile(providerID: "local"))
    }

    func testImportsEnvironmentCredentialAsReferenceOnly() throws {
        let data = Data(
            #"""
            {
              "model": "openai/test-model",
              "provider": {
                "openai": {
                  "options": { "apiKey": "{env:TEST_PROVIDER_KEY}" },
                  "models": { "test-model": "Test Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(data: data)

        XCTAssertEqual(
            imported.providers[0].endpoint.apiKeyRef,
            .environment("TEST_PROVIDER_KEY"))
        XCTAssertTrue(imported.literalSecretProviderIDs.isEmpty)
        XCTAssertEqual(
            imported.warnings,
            [.externalCredentialReference(
                providerID: "openai",
                kind: "environment")])
    }

    func testImportsSeparateBackgroundWebSearchRoute() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "web_search_model": "search/search-model",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                },
                "search": {
                  "options": {
                    "baseURL": "https://search.example.test/v1",
                    "responsesEndpoint": "https://search.example.test/responses"
                  },
                  "models": { "search-model": "Search Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])

        XCTAssertEqual(imported.selectedProviderID, "chat")
        XCTAssertEqual(imported.selectedModelID, "chat-model")
        XCTAssertEqual(
            imported.webSearchModel,
            ModelRef(
                endpoint: "search",
                model: ModelID(rawValue: "search-model")))
        XCTAssertEqual(
            imported.providerConfig.models.webSearch,
            imported.webSearchModel)
        XCTAssertEqual(
            imported.providers.first { $0.id == "search" }?
                .endpoint.responsesEndpoint?.absoluteString,
            "https://search.example.test/responses")
    }

    func testImportsExplicitTranscriptionRouteWithoutAddingItToChatModels() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "transcription_model": "speech/whisper-test",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                },
                "speech": {
                  "baseURL": "https://speech.example.test/v1",
                  "models": {}
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])

        let expected = ModelRef(
            endpoint: "speech",
            model: ModelID(rawValue: "whisper-test"))
        XCTAssertEqual(imported.transcriptionModel, expected)
        XCTAssertEqual(
            imported.providerConfig.models.transcription,
            expected)
        XCTAssertEqual(
            imported.providers.first { $0.id == "speech" }?.models,
            [])
        XCTAssertEqual(imported.selectedProviderID, "chat")
        XCTAssertEqual(imported.selectedModelID, "chat-model")
    }

    func testImportsIndependentKnowledgeRoutesWithoutAddingThemToChatModels() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "embedding_model": "embedding/BAAI/bge-m3",
              "reranker_model": "reranker/BAAI/bge-reranker-v2-m3",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                },
                "embedding": {
                  "npm": "intatis:siliconflow-v1",
                  "baseURL": "https://embedding.example.test/v1",
                  "models": {}
                },
                "reranker": {
                  "npm": "intatis:cohere-v2",
                  "baseURL": "https://reranker.example.test/v2",
                  "models": {}
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])
        let embedding = ModelRef(
            endpoint: "embedding",
            model: ModelID(rawValue: "BAAI/bge-m3"))
        let reranker = ModelRef(
            endpoint: "reranker",
            model: ModelID(rawValue: "BAAI/bge-reranker-v2-m3"))

        XCTAssertEqual(imported.embeddingModel, embedding)
        XCTAssertEqual(imported.rerankerModel, reranker)
        XCTAssertEqual(imported.providerConfig.models.embedding, embedding)
        XCTAssertEqual(imported.providerConfig.models.reranker, reranker)
        XCTAssertEqual(
            imported.providers.first { $0.id == "embedding" }?.models,
            [])
        XCTAssertEqual(
            imported.providers.first { $0.id == "reranker" }?.models,
            [])
        XCTAssertEqual(imported.selectedProviderID, "chat")
        XCTAssertEqual(imported.selectedModelID, "chat-model")
    }

    func testKnowledgeRolesRejectImplicitChatProviderFallback() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "embedding_model": "BAAI/bge-m3",
              "reranker_model": "chat/reranker-model",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                }
              }
            }
            """#.utf8)

        XCTAssertThrowsError(try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])) {
            XCTAssertEqual(
                $0 as? ChatConfigurationImportError,
                .invalidModelSelection)
        }
    }

    func testWebSearchModelDefaultsToOrdinaryChatRouteWhenOmitted() throws {
        let data = Data(
            #"""
            {
              "model": "openai/test-model",
              "provider": {
                "openai": {
                  "models": { "test-model": "Test Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(data: data)

        XCTAssertNil(imported.webSearchModel)
        XCTAssertNil(imported.providerConfig.models.webSearch)
    }

    func testLegacyWebSearchModelDoesNotAddAHiddenVisibleModel() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "web_search_model": "chat/hidden-search-model",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])

        XCTAssertEqual(
            imported.webSearchModel,
            ModelRef(
                endpoint: "chat",
                model: ModelID(rawValue: "hidden-search-model")))
        XCTAssertEqual(imported.providers[0].models.map(\.id), ["chat-model"])
    }

    func testInvalidLegacyWebSearchModelDoesNotBlockOrdinaryChat() throws {
        let data = Data(
            #"""
            {
              "model": "chat/chat-model",
              "web_search_model": "/",
              "provider": {
                "chat": {
                  "baseURL": "https://chat.example.test/v1",
                  "models": { "chat-model": "Chat Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(
            data: data,
            environment: [:])

        XCTAssertEqual(imported.selectedProviderID, "chat")
        XCTAssertEqual(imported.selectedModelID, "chat-model")
        XCTAssertNil(imported.webSearchModel)
    }

    func testSkipsUnknownProviderWithoutBaseURLWhenAnotherRouteIsUsable() throws {
        let data = Data(
            #"""
            {
              "model": "openai/test-model",
              "provider": {
                "anthropic": {
                  "npm": "@ai-sdk/anthropic",
                  "models": { "claude-test": "Claude Test" }
                },
                "openai": {
                  "models": { "test-model": "Test Model" }
                }
              }
            }
            """#.utf8)

        let imported = try ChatConfigurationImporter.parse(data: data)

        XCTAssertEqual(imported.providers.map(\.id), ["openai"])
        XCTAssertEqual(imported.selectedModelID, "test-model")
        XCTAssertEqual(
            imported.warnings,
            [.skippedProviderWithoutBaseURL(providerID: "anthropic")])
    }

    func testRejectsOversizedAndCredentialBearingEndpointDocuments() throws {
        XCTAssertThrowsError(try ChatConfigurationImporter.parse(
            data: Data(repeating: 0x20,
                       count: ChatConfigurationImporter.maximumByteCount + 1))) {
            XCTAssertEqual(
                $0 as? ChatConfigurationImportError,
                .fileTooLarge)
        }

        let invalid = Data(
            #"""
            {
              "provider": {
                "bad": {
                  "baseURL": "https://user:password@example.test/v1",
                  "models": { "model": "Model" }
                }
              }
            }
            """#.utf8)
        XCTAssertThrowsError(try ChatConfigurationImporter.parse(data: invalid)) {
            XCTAssertEqual(
                $0 as? ChatConfigurationImportError,
                .invalidProviderEndpoint)
        }
    }
}
