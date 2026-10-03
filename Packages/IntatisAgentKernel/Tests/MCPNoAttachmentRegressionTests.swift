import Foundation
import XCTest
import IntatisConversation
import IntatisCore
import IntatisPermission
import IntatisProtocol
@testable import IntatisProviders
import IntatisTools
@testable import IntatisAgentKernel

private final class MCPNoAttachmentCapturingProvider:
    ToolCallingProvider, @unchecked Sendable {
    let toolCallingCapabilities: ToolCallingProviderCapabilities

    private let lock = NSLock()
    private var requestStorage: [AgentRequest] = []

    init(
        capabilities: ToolCallingProviderCapabilities =
            .chatCompletionsOnly
    ) {
        toolCallingCapabilities = capabilities
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        requestStorage.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("unchanged"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

private struct MCPNoAttachmentWireHTTP: HTTPByteStreaming {
    func stream(
        _: URLRequest
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor MCPNoAttachmentSnapshotProbe {
    private var capabilities:
        [ToolCallingProviderCapabilities] = []

    func record(_ value: ToolCallingProviderCapabilities) {
        capabilities.append(value)
    }

    func values() -> [ToolCallingProviderCapabilities] {
        capabilities
    }
}

private struct MCPNoAttachmentBaseTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "base_read_tool",
        description: "Existing non-MCP base tool.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ]))

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        ToolObservation(text: "unused")
    }
}

final class MCPNoAttachmentRegressionTests: XCTestCase {
    func testNoAttachmentSnapshotSeamPreservesProviderRequestSemantics()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-no-mcp-regression-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = ToolRegistry([MCPNoAttachmentBaseTool()])
        let capabilities =
            ToolCallingProviderCapabilities.responsesToolSearch
        let baselineProvider = MCPNoAttachmentCapturingProvider(
            capabilities: capabilities)
        let baselineOutput = try await Self.run(
            provider: baselineProvider,
            registry: registry,
            workspace: workspace,
            session: "no-mcp-baseline",
            eventFile: "baseline-events.jsonl",
            toolSnapshotProvider: nil)

        let snapshotProbe = MCPNoAttachmentSnapshotProbe()
        let snapshotProvider = MCPNoAttachmentCapturingProvider(
            capabilities: capabilities)
        let seamOutput = try await Self.run(
            provider: snapshotProvider,
            registry: registry,
            workspace: workspace,
            session: "no-mcp-snapshot-seam",
            eventFile: "snapshot-events.jsonl",
            toolSnapshotProvider: {
                capabilities,
                _ in
                await snapshotProbe.record(capabilities)
                return AgentRequestToolSnapshot(registry: registry)
            })

        XCTAssertEqual(baselineOutput, "unchanged")
        XCTAssertEqual(seamOutput, baselineOutput)
        let baselineRequest = try XCTUnwrap(
            baselineProvider.requests.first)
        let seamRequest = try XCTUnwrap(
            snapshotProvider.requests.first)
        XCTAssertEqual(baselineProvider.requests.count, 1)
        XCTAssertEqual(snapshotProvider.requests.count, 1)

        // These are every AgentRequest field that affects provider request
        // selection or wire construction. The seam must be behaviorally inert
        // when the session has no MCP attachment.
        XCTAssertEqual(seamRequest.model, baselineRequest.model)
        XCTAssertEqual(seamRequest.messages, baselineRequest.messages)
        XCTAssertEqual(seamRequest.tools, baselineRequest.tools)
        XCTAssertEqual(
            seamRequest.effectiveInputItems,
            baselineRequest.effectiveInputItems)
        XCTAssertEqual(
            seamRequest.temperature,
            baselineRequest.temperature)
        XCTAssertEqual(
            seamRequest.reasoningEffort,
            baselineRequest.reasoningEffort)
        XCTAssertEqual(
            seamRequest.includeUsage,
            baselineRequest.includeUsage)
        XCTAssertEqual(
            seamRequest.parallelToolCalls,
            baselineRequest.parallelToolCalls)
        XCTAssertEqual(
            seamRequest.maxOutputTokens,
            baselineRequest.maxOutputTokens)
        XCTAssertEqual(
            seamRequest.requiresResponsesAPI,
            baselineRequest.requiresResponsesAPI)
        XCTAssertFalse(seamRequest.requiresResponsesAPI)
        let observedCapabilities =
            await snapshotProbe.values()
        XCTAssertEqual(
            observedCapabilities,
            [capabilities])

        // Compare the actual OpenAI-compatible URLRequest, not merely the
        // provider-neutral AgentRequest. A no-attachment session must not add
        // tool_search, change routes, headers, or mutate one byte of the body.
        let baselineWire = try Self.makeWireRequest(
            baselineRequest,
            capabilities: capabilities)
        let seamWire = try Self.makeWireRequest(
            seamRequest,
            capabilities: capabilities)
        XCTAssertEqual(seamWire.url, baselineWire.url)
        XCTAssertEqual(seamWire.httpMethod, baselineWire.httpMethod)
        XCTAssertEqual(
            seamWire.allHTTPHeaderFields,
            baselineWire.allHTTPHeaderFields)
        XCTAssertEqual(seamWire.httpBody, baselineWire.httpBody)
        XCTAssertEqual(seamWire.url?.path, "/v1/chat/completions")

        // The canonical durable log keeps the same event types and payload
        // schemas, and emits no MCP event, when the optional snapshot seam is
        // present but the session has no MCP attachment.
        let baselineLog = try EventLog(
            session: SessionID(rawValue: "no-mcp-baseline"),
            fileURL: workspace.appendingPathComponent(
                "baseline-events.jsonl"))
        let seamLog = try EventLog(
            session: SessionID(rawValue: "no-mcp-snapshot-seam"),
            fileURL: workspace.appendingPathComponent(
                "snapshot-events.jsonl"))
        let baselineEnvelopes =
            try await baselineLog.replayChecked()
        let seamEnvelopes =
            try await seamLog.replayChecked()
        let baselineSchema = try Self.eventSchema(
            baselineEnvelopes)
        let seamSchema = try Self.eventSchema(seamEnvelopes)
        XCTAssertEqual(seamSchema, baselineSchema)
        XCTAssertFalse(
            seamSchema.contains {
                $0.type.hasPrefix("mcp_")
            })

        let baselineProjection =
            CodeProjection.build(from: baselineEnvelopes)
                .items.map(Self.presentationSemantics)
        let seamProjection =
            CodeProjection.build(from: seamEnvelopes)
                .items.map(Self.presentationSemantics)
        XCTAssertEqual(seamProjection, baselineProjection)
    }

    private struct EventSchema: Equatable {
        let type: String
        let version: Int
        let payloadKeys: [String]
    }

    private static func makeWireRequest(
        _ request: AgentRequest,
        capabilities: ToolCallingProviderCapabilities
    ) throws -> URLRequest {
        let provider = OpenAIWireProvider(
            endpoint: ProviderEndpoint(
                id: "no-mcp-wire",
                baseURL: URL(
                    string: "https://example.test/v1")!,
                apiKeyRef: KeychainRef(
                    service: "test",
                    account: "no-mcp"),
                wire: .openai),
            apiKey: "test-key",
            http: MCPNoAttachmentWireHTTP(),
            toolCallingCapabilities: capabilities)
        return try provider.buildAgentRequest(request)
    }

    private static func eventSchema(
        _ envelopes: [Envelope]
    ) throws -> [EventSchema] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try envelopes.map { envelope in
            let data = try encoder.encode(envelope)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data)
                    as? [String: Any])
            let type = try XCTUnwrap(object["type"] as? String)
            let payload = try XCTUnwrap(
                object["payload"] as? [String: Any])
            return EventSchema(
                type: type,
                version: try XCTUnwrap(object["v"] as? Int),
                payloadKeys: payload.keys.sorted())
        }
    }

    private static func presentationSemantics(
        _ item: CodeItem
    ) -> [String] {
        [
            item.kind.rawValue,
            item.presentationSource.rawValue,
            item.title,
            item.body,
            item.complete ? "complete" : "incomplete",
            item.files.joined(separator: "\u{1f}"),
            item.tags.joined(separator: "\u{1f}"),
            item.goal ?? "",
            item.isFailure ? "failure" : "success",
            item.submissionStatus?.rawValue ?? "",
            item.submissionAttempt.map(String.init) ?? "",
        ]
    }

    private static func run(
        provider: any ToolCallingProvider,
        registry: ToolRegistry,
        workspace: URL,
        session: String,
        eventFile: String,
        toolSnapshotProvider:
            AgentRequestToolSnapshotProvider?
    ) async throws -> String {
        let log = try EventLog(
            session: SessionID(rawValue: session),
            fileURL: workspace.appendingPathComponent(eventFile))
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: AgentID(rawValue: "no-mcp-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "no-mcp-model"),
                profile: .reviewed),
            allowsShell: false,
            toolSnapshotProvider: toolSnapshotProvider)
        return try await loop.send("unchanged input")
    }
}
