import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisAgentKernel

private final class CapturingHostedChatProvider:
    ChatProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let chunks: [ChatChunk]
    private var storedRequests: [ChatRequest] = []

    init(chunks: [ChatChunk]) {
        self.chunks = chunks
    }

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func stream(
        _ request: ChatRequest
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

final class ProviderHostedWebSearchToolServiceTests: XCTestCase {
    func testUsesExactRouteAndFormatsDeduplicatedProviderSources()
        async throws
    {
        let provider = CapturingHostedChatProvider(chunks: [
            .delta("Current answer."),
            .citation(MessageCitation(
                url: "https://example.test/source",
                title: "Example\nSource")),
            .citation(MessageCitation(
                url: "https://example.test/source",
                title: "Duplicate")),
            .citation(MessageCitation(
                url: "https://second.example.test/",
                title: "Second")),
            .done,
        ])
        let configuration = ChatWebSearchConfiguration(
            dialect: .openRouterServerTool,
            contextSize: .medium,
            unsupportedBehavior: .failClosed,
            toolChoice: .required)
        let service = ProviderHostedWebSearchToolService(
            route: ResolvedHostedWebSearchRoute(
                provider: provider,
                model: ModelID(rawValue: "exact-search-model"),
                configuration: configuration))

        let observation = try await service.search(
            query: "What changed today?")

        XCTAssertFalse(observation.truncated)
        XCTAssertTrue(observation.text.contains("Current answer."))
        XCTAssertTrue(observation.text.contains("Sources:"))
        XCTAssertTrue(observation.text.contains(
            "1. Example Source — https://example.test/source"))
        XCTAssertTrue(observation.text.contains(
            "2. Second — https://second.example.test/"))
        XCTAssertFalse(observation.text.contains("Duplicate"))

        let request = try XCTUnwrap(provider.requests.single)
        XCTAssertEqual(request.model.rawValue, "exact-search-model")
        XCTAssertEqual(request.webSearch, configuration)
        XCTAssertNil(request.temperature)
        XCTAssertNil(request.reasoningEffort)
        XCTAssertFalse(request.includeUsage)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertTrue(request.messages[0].content.contains(
            "provider-hosted web search"))
        XCTAssertEqual(request.messages[1], ChatMessage(
            role: .user,
            content: "What changed today?"))
    }

    func testRejectsStreamThatEndsWithoutProviderCompletion() async {
        let provider = CapturingHostedChatProvider(chunks: [
            .delta("partial"),
        ])
        let service = ProviderHostedWebSearchToolService(
            route: ResolvedHostedWebSearchRoute(
                provider: provider,
                model: ModelID(rawValue: "exact-search-model"),
                configuration: ChatWebSearchConfiguration(
                    dialect: .openAIResponses,
                    unsupportedBehavior: .failClosed,
                    toolChoice: .required)))

        do {
            _ = try await service.search(query: "latest")
            XCTFail("incomplete provider stream unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "ended before completion"))
        }
    }

    func testBoundsOversizedProviderOutput() async throws {
        let provider = CapturingHostedChatProvider(chunks: [
            .delta(String(repeating: "x", count: 50_100)),
            .done,
        ])
        let service = ProviderHostedWebSearchToolService(
            route: ResolvedHostedWebSearchRoute(
                provider: provider,
                model: ModelID(rawValue: "exact-search-model"),
                configuration: ChatWebSearchConfiguration(
                    dialect: .openAIResponses,
                    unsupportedBehavior: .failClosed,
                    toolChoice: .required)))

        let observation = try await service.search(query: "latest")

        XCTAssertTrue(observation.truncated)
        XCTAssertTrue(observation.text.hasSuffix("\n[truncated]"))
        XCTAssertLessThanOrEqual(observation.text.count, 50_012)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
