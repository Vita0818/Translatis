import Foundation
import IntatisCore
import IntatisProtocol
import Logging
import MCP
import XCTest
@testable import IntatisMCP

final class MCPInboundCallbackSessionTests: XCTestCase {
    func testProfileSurfacesAreExactAndExperimentalTasksAreExhaustive() throws {
        let codexSurface = MCPClientCallbackCapabilities.complete(
            for: .codexCompat)
        try codexSurface.validate(for: .codexCompat)
        let codex = SDKPatchCompatibility.makeCapabilityProbe(
            profile: .codexCompat,
            callbacks: codexSurface)
        XCTAssertNotNil(codex.elicitation?.form)
        XCTAssertNil(codex.elicitation?.url)
        XCTAssertNil(codex.sampling)
        XCTAssertNil(codex.tasks)
        XCTAssertNil(codex.roots)

        let extendedSurface = MCPClientCallbackCapabilities.complete(
            for: .standardExtended)
        try extendedSurface.validate(for: .standardExtended)
        let extended = SDKPatchCompatibility.makeCapabilityProbe(
            profile: .standardExtended,
            callbacks: extendedSurface)
        XCTAssertNotNil(extended.sampling?.tools)
        XCTAssertNil(extended.sampling?.context)
        XCTAssertNotNil(extended.elicitation?.form)
        XCTAssertNotNil(extended.elicitation?.url)
        XCTAssertNotNil(extended.roots)
        XCTAssertNotNil(extended.tasks?.list)
        XCTAssertNotNil(extended.tasks?.cancel)
        XCTAssertNotNil(
            extended.tasks?.requests?.sampling?.createMessage)
        XCTAssertNotNil(
            extended.tasks?.requests?.elicitation?.create)

        XCTAssertThrowsError(
            try MCPClientCallbackCapabilities(
                taskList: true,
                taskCancel: true)
                .validate(for: .standardExtended)
        ) { error in
            guard case MCPClientSessionError
                    .invalidInboundCapabilitySurface = error else {
                return XCTFail("unexpected partial-task error \(error)")
            }
        }
    }

    func testCodexCompatInstallsDurableFormHandlerBeforeInitialize() async throws {
        let transport = InboundCallbackTransport(
            selectedVersion: "2025-06-18")
        let events = InboundEventSink()
        let payloads = InboundPayloadStore()
        let factory = MCPBrokerInboundServicesFactory(
            events: events,
            payloadStore: payloads,
            elicitation: .init(
                policy: .init(formEnabled: true),
                reviewer: InboundElicitationReviewer(
                    content: ["choice": .string("yes")])))
        let session = MCPClientSession(
            configuration: callbackConfiguration(
                profile: .codexCompat,
                factory: factory),
            transport: transport)
        _ = try await session.start()

        let initializePayload = await transport.initializePayload()
        let initialize = try XCTUnwrap(initializePayload)
        let initializeObject = try JSONSerialization.jsonObject(
            with: initialize) as? [String: Any]
        let params = initializeObject?["params"] as? [String: Any]
        let capabilities = params?["capabilities"] as? [String: Any]
        let elicitation = capabilities?["elicitation"] as? [String: Any]
        XCTAssertNotNil(elicitation?["form"])
        XCTAssertNil(elicitation?["url"])
        XCTAssertNil(capabilities?["sampling"])
        XCTAssertNil(capabilities?["tasks"])

        try await transport.injectRequest(
            id: "form-1",
            method: "elicitation/create",
            params: [
                "message": "Choose a value",
                "requestedSchema": [
                    "type": "object",
                    "properties": [
                        "choice": [
                            "type": "string",
                            "enum": ["yes", "no"],
                        ],
                    ],
                    "required": ["choice"],
                ],
            ])
        let response = try await transport.waitForResponse(id: "form-1")
        let responseObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: response)
                as? [String: Any])
        let result = try XCTUnwrap(
            responseObject["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "accept")
        let content = result["content"] as? [String: Any]
        XCTAssertEqual(content?["choice"] as? String, "yes")
        XCTAssertNil(responseObject["error"])

        let recorded = await events.values()
        XCTAssertEqual(recorded.count, 3)
        guard case .mcpElicitationRequested = recorded[0],
              case .mcpElicitationDecided = recorded[1],
              case .mcpElicitationSettled = recorded[2] else {
            return XCTFail("form lifecycle was not durably ordered")
        }
        let payloadCount = await payloads.count()
        XCTAssertEqual(payloadCount, 1)
        await session.shutdown()
    }

    func testExtendedTaskAugmentedElicitationExposesAllHostedTaskMethods() async throws {
        let transport = InboundCallbackTransport(
            selectedVersion: "2025-11-25")
        let events = InboundEventSink()
        let payloads = InboundPayloadStore()
        let binding = inboundBinding()
        let factory = MCPBrokerInboundServicesFactory(
            events: events,
            payloadStore: payloads,
            sampling: .init(
                policy: .init(
                    enabled: true,
                    allowedInferenceBindings: [binding]),
                reviewer: InboundSamplingReviewer(binding: binding),
                inference: InboundSamplingInference()),
            elicitation: .init(
                policy: .init(
                    formEnabled: true,
                    urlEnabled: true,
                    allowedURLOrigins: [
                        "https://connect.example.test",
                    ]),
                reviewer: InboundElicitationReviewer(
                    content: ["answer": .string("approved")])))
        let session = MCPClientSession(
            configuration: callbackConfiguration(
                profile: .standardExtended,
                factory: factory),
            transport: transport)
        _ = try await session.start()

        try await transport.injectRequest(
            id: "task-create-1",
            method: "elicitation/create",
            params: [
                "task": ["ttl": 60_000],
                "mode": "form",
                "message": "Provide an answer",
                "requestedSchema": [
                    "type": "object",
                    "properties": [
                        "answer": ["type": "string"],
                    ],
                    "required": ["answer"],
                ],
            ])
        let creationData = try await transport.waitForResponse(
            id: "task-create-1")
        let creationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: creationData)
                as? [String: Any])
        let creationResult = try XCTUnwrap(
            creationObject["result"] as? [String: Any])
        let task = try XCTUnwrap(
            creationResult["task"] as? [String: Any])
        let taskID = try XCTUnwrap(task["taskId"] as? String)
        XCTAssertEqual(task["status"] as? String, "input_required")
        XCTAssertNil(creationResult["action"])

        try await transport.injectRequest(
            id: "task-get-1",
            method: "tasks/get",
            params: ["taskId": taskID])
        let getData = try await transport.waitForResponse(id: "task-get-1")
        let getObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: getData)
                as? [String: Any])
        let getResult = try XCTUnwrap(
            getObject["result"] as? [String: Any])
        XCTAssertEqual(getResult["taskId"] as? String, taskID)
        XCTAssertTrue(
            ["input_required", "completed"]
                .contains(getResult["status"] as? String ?? ""))

        try await transport.injectRequest(
            id: "task-list-1",
            method: "tasks/list",
            params: [:])
        let listData = try await transport.waitForResponse(id: "task-list-1")
        let listObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: listData)
                as? [String: Any])
        let listResult = try XCTUnwrap(
            listObject["result"] as? [String: Any])
        let listedTasks = try XCTUnwrap(
            listResult["tasks"] as? [[String: Any]])
        XCTAssertEqual(listedTasks.map { $0["taskId"] as? String }, [taskID])

        try await transport.injectRequest(
            id: "task-result-1",
            method: "tasks/result",
            params: ["taskId": taskID])
        let resultData = try await transport.waitForResponse(
            id: "task-result-1")
        let resultObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: resultData)
                as? [String: Any])
        let hostedResult = try XCTUnwrap(
            resultObject["result"] as? [String: Any])
        XCTAssertEqual(hostedResult["action"] as? String, "accept")
        let meta = hostedResult["_meta"] as? [String: Any]
        let related = meta?[MCPRelatedTaskMetadataKey]
            as? [String: Any]
        XCTAssertEqual(related?["taskId"] as? String, taskID)

        try await transport.injectRequest(
            id: "task-cancel-1",
            method: "tasks/cancel",
            params: ["taskId": taskID])
        let cancelData = try await transport.waitForResponse(
            id: "task-cancel-1")
        let cancelObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: cancelData)
                as? [String: Any])
        let cancelResult = try XCTUnwrap(
            cancelObject["result"] as? [String: Any])
        // Exact duplicate terminal cancellation is idempotent and cannot
        // rewrite a successfully completed task.
        XCTAssertEqual(cancelResult["status"] as? String, "completed")

        let methods = await transport.clientMethods()
        XCTAssertTrue(methods.contains("notifications/tasks/status"))
        await session.shutdown()
    }

    func testAdvertisedCallbackWithoutFactoryFailsBeforeInitialize() async {
        let transport = InboundCallbackTransport(
            selectedVersion: "2025-06-18")
        let configuration = MCPClientSessionConfiguration(
            server: inboundServer(),
            generation: inboundGeneration(),
            profile: .codexCompat,
            clientVersion: "test",
            callbackCapabilities: .complete(for: .codexCompat),
            callbackAuthorityFingerprint: String(repeating: "a", count: 64))
        let session = MCPClientSession(
            configuration: configuration,
            transport: transport)

        do {
            _ = try await session.start()
            XCTFail("capability was advertised without a handler factory")
        } catch {
            XCTAssertEqual(
                error as? MCPClientSessionError,
                .inboundCallbackServicesUnavailable(
                    "configured surface"))
        }
        let initializePayload = await transport.initializePayload()
        XCTAssertNil(initializePayload)
    }

    private func callbackConfiguration(
        profile: MCPProtocolProfile,
        factory: any MCPClientInboundServicesFactory
    ) -> MCPClientSessionConfiguration {
        MCPClientSessionConfiguration(
            server: inboundServer(),
            generation: inboundGeneration(),
            profile: profile,
            startupTimeoutMilliseconds: 1_000,
            callTimeoutMilliseconds: 1_000,
            clientVersion: "test",
            callbackCapabilities: .complete(for: profile),
            callbackAuthorityFingerprint: String(repeating: "a", count: 64),
            inboundServicesFactory: factory)
    }
}

private func inboundServer() -> MCPServerReference {
    MCPServerReference(
        serverID: MCPServerID(rawValue: "callback-session"),
        serverRevision: MCPServerRevision(
            rawValue: "callback-session-revision"))
}

private func inboundGeneration() -> MCPConnectionGeneration {
    MCPConnectionGeneration(rawValue: "callback-generation")
}

private func inboundBinding() -> AgentInferenceBinding {
    AgentInferenceBinding(
        inferenceProfileRef: InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(
                rawValue: "callback-sampling"),
            inferenceProfileRevision: InferenceProfileRevision(
                rawValue: "callback-profile-revision")),
        inferenceConnectionID: InferenceConnectionID(
            rawValue: "callback-connection"),
        inferenceConnectionRevision: InferenceConnectionRevision(
            rawValue: "callback-connection-revision"),
        modelID: ModelID(rawValue: "callback-model"),
        immutableDefinitionFingerprint: String(repeating: "b", count: 64))
}

private actor InboundCallbackTransport: Transport {
    nonisolated let logger = Logger(
        label: "intatis.mcp.tests.inbound-callback")

    private let selectedVersion: String
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation:
        AsyncThrowingStream<Data, Error>.Continuation
    private var initializeData: Data?
    private var responses: [String: Data] = [:]
    private var methods: [String] = []

    init(selectedVersion: String) {
        self.selectedVersion = selectedVersion
        var continuation:
            AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream {
            continuation = $0
        }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    func send(_ data: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(
            with: data) as? [String: Any] else {
            return
        }
        if let method = object["method"] as? String {
            methods.append(method)
            if method == "initialize" {
                initializeData = data
                try yieldResponse(
                    id: object["id"],
                    result: [
                        "protocolVersion": selectedVersion,
                        "capabilities": [:],
                        "serverInfo": [
                            "name": "callback-fixture",
                            "version": "1.0",
                        ],
                    ])
            }
            return
        }
        if let id = Self.idString(object["id"]) {
            responses[id] = data
        }
    }

    func injectRequest(
        id: String,
        method: String,
        params: [String: Any]
    ) throws {
        continuation.yield(try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            ]))
    }

    func waitForResponse(
        id: String,
        timeoutMilliseconds: Int = 1_000
    ) async throws -> Data {
        let iterations = max(1, timeoutMilliseconds / 5)
        for _ in 0..<iterations {
            if let value = responses[id] {
                return value
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw InboundCallbackFixtureError.timedOut(id)
    }

    func initializePayload() -> Data? {
        initializeData
    }

    func clientMethods() -> [String] {
        methods
    }

    private func yieldResponse(
        id: Any?,
        result: [String: Any]
    ) throws {
        continuation.yield(try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "result": result,
            ]))
    }

    private static func idString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }
}

private enum InboundCallbackFixtureError: Error {
    case timedOut(String)
}

private actor InboundEventSink: MCPBrokerEventSink {
    private var recorded: [Event] = []

    func appendMCPBrokerEvent(_ event: Event) async throws {
        recorded.append(event)
    }

    func appendMCPBrokerEvents(_ events: [Event]) async throws {
        recorded.append(contentsOf: events)
    }

    func values() -> [Event] {
        recorded
    }
}

private actor InboundPayloadStore: MCPBrokerPayloadStore {
    private struct Entry: Sendable {
        let scope: String
        let payload: Data
    }

    private var entries: [MCPResultReference: Entry] = [:]

    func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference {
        let reference = MCPResultReference.new()
        entries[reference] = Entry(
            scope: scopeFingerprint,
            payload: payload)
        return reference
    }

    func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data {
        guard let entry = entries[reference],
              entry.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        return entry.payload
    }

    func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws {
        guard entries[reference]?.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        entries[reference] = nil
    }

    func count() -> Int {
        entries.count
    }
}

private actor InboundElicitationReviewer:
    MCPElicitationReviewService
{
    private let content: [String: Value]?

    init(content: [String: Value]?) {
        self.content = content
    }

    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview {
        switch presentation.parameters {
        case .form:
            return .accept(content: content)
        case .url:
            return .accept(content: nil)
        }
    }
}

private actor InboundSamplingReviewer: MCPSamplingReviewService {
    private let binding: AgentInferenceBinding

    init(binding: AgentInferenceBinding) {
        self.binding = binding
    }

    func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async throws -> MCPSamplingRequestReview {
        .allow(
            parameters: presentation.parameters,
            inferenceBinding: binding)
    }

    func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async throws -> MCPSamplingResultReview {
        .allow(presentation.result)
    }
}

private struct InboundSamplingInference:
    MCPSamplingInferenceService
{
    func createSamplingMessage(
        parameters _: CreateSamplingMessage.Parameters,
        inferenceBinding _: AgentInferenceBinding
    ) async throws -> CreateSamplingMessage.Result {
        .init(
            model: "callback-model",
            stopReason: .endTurn,
            role: .assistant,
            content: .text("approved"))
    }
}
