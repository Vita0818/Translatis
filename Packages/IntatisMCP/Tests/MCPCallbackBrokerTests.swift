import Foundation
import IntatisCore
import IntatisProtocol
import MCP
import XCTest
@testable import IntatisMCP

final class MCPCallbackBrokerTests: XCTestCase {
    func testSamplingDisabledFailsClosedBeforeReviewOrInference() async throws {
        let events = BrokerEventRecorder()
        let payloads = MemoryBrokerPayloadStore()
        let reviewer = SamplingApprovalFixture(binding: binding())
        let inference = SamplingInferenceFixture(result: textResult("unused"))
        let broker = MCPSamplingBroker(
            authority: authority(),
            policy: .init(),
            reviewer: reviewer,
            inference: inference,
            events: events,
            payloadStore: payloads)

        do {
            _ = try await broker.handle(.init(
                messages: [.user(.text("hello"))],
                maxTokens: 128))
            XCTFail("disabled sampling unexpectedly ran")
        } catch {
            XCTAssertEqual(
                error as? MCPSamplingBrokerError,
                .disabled)
        }

        let requestReviewCount = await reviewer.requestReviewCount()
        let inferenceCallCount = await inference.callCount()
        XCTAssertEqual(requestReviewCount, 0)
        XCTAssertEqual(inferenceCallCount, 0)
        let recorded = await events.values()
        XCTAssertEqual(recorded.count, 3)
        guard case .mcpSamplingRequested = recorded[0],
              case .mcpSamplingDecided = recorded[1],
              case .mcpSamplingSettled = recorded[2] else {
            return XCTFail("sampling lifecycle was not durable and ordered")
        }
    }

    func testSamplingToolsUseExactBindingAndNeverExecuteHostTools() async throws {
        let selectedBinding = binding()
        let events = BrokerEventRecorder()
        let payloads = MemoryBrokerPayloadStore()
        let reviewer = SamplingApprovalFixture(binding: selectedBinding)
        let inference = SamplingInferenceFixture(result: .init(
            model: "fixture-model",
            stopReason: .toolUse,
            role: .assistant,
            content: .single(.toolUse(.init(
                id: "tool-use-1",
                name: "lookup",
                input: ["query": .string("Paris")])))))
        let broker = MCPSamplingBroker(
            authority: authority(),
            policy: .init(
                enabled: true,
                allowedInferenceBindings: [selectedBinding]),
            reviewer: reviewer,
            inference: inference,
            events: events,
            payloadStore: payloads)
        let tool = Tool(
            name: "lookup",
            description: "Lookup a value",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]))

        let result = try await broker.handle(.init(
            messages: [.user(.text("find weather"))],
            maxTokens: 512,
            tools: [tool],
            toolChoice: .init(mode: .required)))

        XCTAssertEqual(result.stopReason, .toolUse)
        let inferenceCallCount = await inference.callCount()
        let observedBinding = await inference.lastBinding()
        let resultReviewCount = await reviewer.resultReviewCount()
        let protectedPayloadCount = await payloads.count()
        XCTAssertEqual(inferenceCallCount, 1)
        XCTAssertEqual(observedBinding, selectedBinding)
        XCTAssertEqual(resultReviewCount, 1)
        XCTAssertEqual(protectedPayloadCount, 1)
        let recorded = await events.values()
        XCTAssertEqual(recorded.count, 3)
        guard case .mcpSamplingSettled(let settled) = recorded[2] else {
            return XCTFail("missing sampling terminal")
        }
        XCTAssertEqual(settled.status, .succeeded)
        XCTAssertNotNil(settled.resultReference)
    }

    func testSamplingRejectsUnbalancedHistoryAndNonAdvertisedContext() async throws {
        let selectedBinding = binding()
        let events = BrokerEventRecorder()
        let reviewer = SamplingApprovalFixture(binding: selectedBinding)
        let inference = SamplingInferenceFixture(result: textResult("unused"))
        let broker = MCPSamplingBroker(
            authority: authority(),
            policy: .init(
                enabled: true,
                allowedInferenceBindings: [selectedBinding]),
            reviewer: reviewer,
            inference: inference,
            events: events,
            payloadStore: MemoryBrokerPayloadStore())
        let unmatched = Sampling.Message.assistant(.single(.toolUse(.init(
            id: "call-1",
            name: "lookup",
            input: [:]))))

        do {
            _ = try await broker.handle(.init(
                messages: [unmatched, .user(.text("not a tool result"))],
                maxTokens: 64))
            XCTFail("unbalanced sampling history was accepted")
        } catch let error as MCPSamplingBrokerError {
            guard case .malformedRequest = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        do {
            _ = try await broker.handle(.init(
                messages: [.user(.text("hello"))],
                includeContext: .allServers,
                maxTokens: 64))
            XCTFail("non-advertised context inclusion was accepted")
        } catch let error as MCPSamplingBrokerError {
            guard case .malformedRequest = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let requestReviewCount = await reviewer.requestReviewCount()
        let inferenceCallCount = await inference.callCount()
        XCTAssertEqual(requestReviewCount, 0)
        XCTAssertEqual(inferenceCallCount, 0)
    }

    func testSamplingRejectsToolInputThatViolatesServerSchema() async throws {
        let selectedBinding = binding()
        let inference = SamplingInferenceFixture(result: .init(
            model: "fixture-model",
            stopReason: .toolUse,
            role: .assistant,
            content: .single(.toolUse(.init(
                id: "tool-use-invalid",
                name: "lookup",
                input: ["query": .int(42)])))))
        let broker = MCPSamplingBroker(
            authority: authority(),
            policy: .init(
                enabled: true,
                allowedInferenceBindings: [selectedBinding]),
            reviewer: SamplingApprovalFixture(binding: selectedBinding),
            inference: inference,
            events: BrokerEventRecorder(),
            payloadStore: MemoryBrokerPayloadStore())
        let tool = Tool(
            name: "lookup",
            description: nil,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("query")]),
            ]))

        do {
            _ = try await broker.handle(.init(
                messages: [.user(.text("hello"))],
                maxTokens: 128,
                tools: [tool],
                toolChoice: .init(mode: .required)))
            XCTFail("schema-invalid tool use was accepted")
        } catch let error as MCPSamplingBrokerError {
            guard case .invalidModelResult = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testFormElicitationRejectsSecretFieldsBeforeHumanReview() async throws {
        let reviewer = ElicitationReviewFixture(
            review: .accept(content: ["password": .string("secret")]))
        let broker = MCPElicitationBroker(
            authority: authority(profile: .codexCompat),
            policy: .init(formEnabled: true),
            reviewer: reviewer,
            events: BrokerEventRecorder(),
            payloadStore: MemoryBrokerPayloadStore())
        let request = CreateElicitation.Parameters.form(.init(
            message: "Enter your password",
            requestedSchema: .init(properties: [
                "password": .object([
                    "type": .string("string"),
                    "title": .string("Password"),
                ]),
            ])))

        do {
            _ = try await broker.handle(request)
            XCTFail("secret form was accepted")
        } catch let error as MCPElicitationBrokerError {
            guard case .sensitiveFormField = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let reviewCount = await reviewer.callCount()
        XCTAssertEqual(reviewCount, 0)
    }

    func testFormElicitationValidatesAndProtectsAcceptedContent() async throws {
        let events = BrokerEventRecorder()
        let payloads = MemoryBrokerPayloadStore()
        let reviewer = ElicitationReviewFixture(review: .accept(content: [
            "email": .string("person@example.com"),
            "age": .int(30),
            "colors": .array([.string("red"), .string("blue")]),
        ]))
        let broker = MCPElicitationBroker(
            authority: authority(profile: .codexCompat),
            policy: .init(formEnabled: true),
            reviewer: reviewer,
            events: events,
            payloadStore: payloads)
        let schema = Elicitation.RequestSchema(
            properties: [
                "email": .object([
                    "type": .string("string"),
                    "format": .string("email"),
                ]),
                "age": .object([
                    "type": .string("integer"),
                    "minimum": .int(18),
                ]),
                "colors": .object([
                    "type": .string("array"),
                    "minItems": .int(1),
                    "maxItems": .int(2),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("red"), .string("blue"), .string("green"),
                        ]),
                    ]),
                ]),
            ],
            required: ["email", "age"])

        let result = try await broker.handle(.form(.init(
            message: "Share contact preferences",
            requestedSchema: schema)))

        XCTAssertEqual(result.action, .accept)
        XCTAssertEqual(result.content?["age"], .int(30))
        let protectedPayloadCount = await payloads.count()
        XCTAssertEqual(protectedPayloadCount, 1)
        let recorded = await events.values()
        XCTAssertEqual(recorded.count, 3)
        guard case .mcpElicitationSettled(let settled) = recorded[2] else {
            return XCTFail("missing elicitation terminal")
        }
        XCTAssertEqual(settled.status, .succeeded)
        XCTAssertNotNil(settled.resultReference)
    }

    func testURLElicitationIsConsentOnlyAndCompletionIsGenerationLocal() async throws {
        let broker = MCPElicitationBroker(
            authority: authority(),
            policy: .init(
                urlEnabled: true,
                allowedURLOrigins: ["https://connect.example.com"]),
            reviewer: ElicitationReviewFixture(
                review: .accept(content: nil)),
            events: BrokerEventRecorder(),
            payloadStore: MemoryBrokerPayloadStore())
        let acceptedAt = Date(timeIntervalSince1970: 1_000)
        let result = try await broker.handle(.url(.init(
            message: "Connect an external account",
            url: "https://connect.example.com/start?elicitationId=opaque-1",
            elicitationId: "opaque-1")),
            now: acceptedAt)

        XCTAssertEqual(result.action, .accept)
        XCTAssertNil(result.content)
        let pendingState = await broker.URLCompletionState(
            elicitationID: "opaque-1",
            now: acceptedAt)
        let unknownCompletion = await broker.markURLCompleted(
            elicitationID: "unknown",
            now: acceptedAt)
        let firstCompletion = await broker.markURLCompleted(
            elicitationID: "opaque-1",
            now: acceptedAt)
        let duplicateCompletion = await broker.markURLCompleted(
            elicitationID: "opaque-1",
            now: acceptedAt)
        let completedState = await broker.URLCompletionState(
            elicitationID: "opaque-1",
            now: acceptedAt)
        XCTAssertEqual(pendingState, .pending)
        XCTAssertFalse(unknownCompletion)
        XCTAssertTrue(firstCompletion)
        XCTAssertFalse(duplicateCompletion)
        XCTAssertEqual(completedState, .completed)
    }

    func testURLElicitationRejectsCodexProfileAndCredentialQuery() async throws {
        let codexBroker = MCPElicitationBroker(
            authority: authority(profile: .codexCompat),
            policy: .init(urlEnabled: true),
            reviewer: ElicitationReviewFixture(
                review: .accept(content: nil)),
            events: BrokerEventRecorder(),
            payloadStore: MemoryBrokerPayloadStore())
        do {
            _ = try await codexBroker.handle(.url(.init(
                message: "Connect",
                url: "https://connect.example.com/start",
                elicitationId: "one")))
            XCTFail("codex-compat advertised URL elicitation")
        } catch {
            XCTAssertEqual(
                error as? MCPElicitationBrokerError,
                .unsupportedMode)
        }

        let standardBroker = MCPElicitationBroker(
            authority: authority(),
            policy: .init(urlEnabled: true),
            reviewer: ElicitationReviewFixture(
                review: .accept(content: nil)),
            events: BrokerEventRecorder(),
            payloadStore: MemoryBrokerPayloadStore())
        do {
            _ = try await standardBroker.handle(.url(.init(
                message: "Connect",
                url: "https://connect.example.com/start?access_token=secret",
                elicitationId: "two")))
            XCTFail("credential-bearing URL was accepted")
        } catch {
            XCTAssertEqual(
                error as? MCPElicitationBrokerError,
                .unsafeURL)
        }
    }

    private func authority(
        profile: MCPProtocolProfile = .standardExtended
    ) -> MCPCallbackAuthorityContext {
        MCPCallbackAuthorityContext(
            server: MCPServerReference(
                serverID: MCPServerID(rawValue: "mcpserver-callback"),
                serverRevision: MCPServerRevision(rawValue: "mcprev-callback")),
            connectionGeneration: MCPConnectionGeneration(
                rawValue: "mcpcnx-callback"),
            authorityFingerprint: String(repeating: "a", count: 64),
            profile: profile)
    }

    private func binding() -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(
                    rawValue: "mcp-sampling"),
                inferenceProfileRevision: InferenceProfileRevision(
                    rawValue: "profile-revision")),
            inferenceConnectionID: InferenceConnectionID(
                rawValue: "sampling-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(
                rawValue: "connection-revision"),
            modelID: ModelID(rawValue: "fixture-model"),
            immutableDefinitionFingerprint: String(repeating: "b", count: 64))
    }

    private func textResult(
        _ text: String
    ) -> CreateSamplingMessage.Result {
        .init(
            model: "fixture-model",
            stopReason: .endTurn,
            role: .assistant,
            content: .text(text))
    }
}

private actor BrokerEventRecorder: MCPBrokerEventSink {
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

private actor MemoryBrokerPayloadStore: MCPBrokerPayloadStore {
    private struct Entry: Sendable {
        let scope: String
        let data: Data
    }

    private var values: [MCPResultReference: Entry] = [:]

    func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference {
        let reference = MCPResultReference.new()
        values[reference] = Entry(
            scope: scopeFingerprint,
            data: payload)
        return reference
    }

    func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data {
        guard let entry = values[reference],
              entry.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        return entry.data
    }

    func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws {
        guard let entry = values[reference],
              entry.scope == scopeFingerprint else {
            throw MCPSecretStoreError.notFound
        }
        values[reference] = nil
    }

    func count() -> Int {
        values.count
    }
}

private actor SamplingApprovalFixture: MCPSamplingReviewService {
    private let binding: AgentInferenceBinding
    private var requestCount = 0
    private var resultCount = 0

    init(binding: AgentInferenceBinding) {
        self.binding = binding
    }

    func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async throws -> MCPSamplingRequestReview {
        requestCount += 1
        return .allow(
            parameters: presentation.parameters,
            inferenceBinding: binding)
    }

    func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async throws -> MCPSamplingResultReview {
        resultCount += 1
        return .allow(presentation.result)
    }

    func requestReviewCount() -> Int {
        requestCount
    }

    func resultReviewCount() -> Int {
        resultCount
    }
}

private actor SamplingInferenceFixture: MCPSamplingInferenceService {
    private let result: CreateSamplingMessage.Result
    private var calls = 0
    private var observedBinding: AgentInferenceBinding?

    init(result: CreateSamplingMessage.Result) {
        self.result = result
    }

    func createSamplingMessage(
        parameters: CreateSamplingMessage.Parameters,
        inferenceBinding: AgentInferenceBinding
    ) async throws -> CreateSamplingMessage.Result {
        calls += 1
        observedBinding = inferenceBinding
        return result
    }

    func callCount() -> Int {
        calls
    }

    func lastBinding() -> AgentInferenceBinding? {
        observedBinding
    }
}

private actor ElicitationReviewFixture: MCPElicitationReviewService {
    private let review: MCPElicitationReview
    private var calls = 0

    init(review: MCPElicitationReview) {
        self.review = review
    }

    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview {
        calls += 1
        return review
    }

    func callCount() -> Int {
        calls
    }
}
