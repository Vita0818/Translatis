import Foundation
import IntatisCore
import IntatisProtocol
import MCP

/// Exact, immutable authority carried by every server-to-client callback.
///
/// A callback broker never derives this authority from a process-global
/// connection. The connection owner supplies the frozen server revision,
/// generation and authority fingerprint that received the wire request.
public struct MCPCallbackAuthorityContext: Equatable, Hashable, Sendable {
    public let server: MCPServerReference
    public let connectionGeneration: MCPConnectionGeneration
    public let authorityFingerprint: String
    public let profile: MCPProtocolProfile

    public init(
        server: MCPServerReference,
        connectionGeneration: MCPConnectionGeneration,
        authorityFingerprint: String,
        profile: MCPProtocolProfile
    ) {
        self.server = server
        self.connectionGeneration = connectionGeneration
        self.authorityFingerprint = authorityFingerprint
        self.profile = profile
    }
}

/// Narrow adapter implemented by a session-owned EventLog bridge.
///
/// The MCP module deliberately does not depend on IntatisConversation. A
/// production broker must receive a durable sink; failure to persist any
/// lifecycle edge fails the callback closed.
public protocol MCPBrokerEventSink: Sendable {
    func appendMCPBrokerEvent(_ event: Event) async throws
    func appendMCPBrokerEvents(_ events: [Event]) async throws
}

/// Protected storage for callback payloads that must not enter ordinary JSONL.
public protocol MCPBrokerPayloadStore: Sendable {
    func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference

    func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data

    func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws
}

/// Uses the already-frozen platform credential backend for bounded callback
/// payloads. macOS therefore stores these bytes in Keychain and CLI stores
/// them in its authenticated encrypted owner-only container.
public actor MCPSecretBackedBrokerPayloadStore: MCPBrokerPayloadStore {
    private let secretStore: any MCPSecretStore

    public init(secretStore: any MCPSecretStore) {
        self.secretStore = secretStore
    }

    public func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference {
        let binding = Self.bindingFingerprint(scopeFingerprint)
        let reference = try await secretStore.store(
            payload,
            sourceBindingFingerprint: binding)
        return MCPResultReference(rawValue: reference.identifier)
    }

    public func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data {
        try await secretStore.resolve(try secretReference(
            reference,
            scopeFingerprint: scopeFingerprint))
    }

    public func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws {
        try await secretStore.remove(try secretReference(
            reference,
            scopeFingerprint: scopeFingerprint))
    }

    private func secretReference(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) throws -> MCPSecretReference {
        try MCPSecretReference(
            storageClass: secretStore.storageClass,
            identifier: reference.rawValue,
            sourceBindingFingerprint: Self.bindingFingerprint(
                scopeFingerprint))
    }

    private static func bindingFingerprint(_ scope: String) -> String {
        MCPConfigurationCanonical.sha256(Data(scope.utf8))
    }
}

// MARK: - Sampling policy and host adapters

public struct MCPSamplingFlowID: RawRepresentable, Codable, Equatable,
    Hashable, Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func new() -> MCPSamplingFlowID {
        MCPSamplingFlowID(rawValue: "mcpsampling-\(UUID().uuidString.lowercased())")
    }
}

public struct MCPSamplingPolicy: Equatable, Sendable {
    public let enabled: Bool
    public let allowedInferenceBindings: Set<AgentInferenceBinding>
    public let maximumRequestBytes: Int
    public let maximumSystemPromptBytes: Int
    public let maximumMessages: Int
    public let maximumTools: Int
    public let maximumToolSchemaBytes: Int
    public let maximumOutputTokensPerRequest: Int
    public let maximumTotalTokensPerFlow: Int
    public let maximumIterationsPerFlow: Int
    public let maximumToolUsesPerFlow: Int
    public let maximumParallelToolUses: Int
    public let maximumRequestsPerMinute: Int
    public let timeoutMilliseconds: Int
    public let maximumStoredResultBytes: Int

    public init(
        enabled: Bool = false,
        allowedInferenceBindings: Set<AgentInferenceBinding> = [],
        maximumRequestBytes: Int = 512 * 1_024,
        maximumSystemPromptBytes: Int = 64 * 1_024,
        maximumMessages: Int = 128,
        maximumTools: Int = 128,
        maximumToolSchemaBytes: Int = 256 * 1_024,
        maximumOutputTokensPerRequest: Int = 16_384,
        maximumTotalTokensPerFlow: Int = 64_000,
        maximumIterationsPerFlow: Int = 16,
        maximumToolUsesPerFlow: Int = 64,
        maximumParallelToolUses: Int = 16,
        maximumRequestsPerMinute: Int = 30,
        timeoutMilliseconds: Int = 120_000,
        maximumStoredResultBytes: Int = 512 * 1_024
    ) {
        self.enabled = enabled
        self.allowedInferenceBindings = allowedInferenceBindings
        self.maximumRequestBytes = max(1_024, maximumRequestBytes)
        self.maximumSystemPromptBytes = max(1_024, maximumSystemPromptBytes)
        self.maximumMessages = max(1, maximumMessages)
        self.maximumTools = max(0, maximumTools)
        self.maximumToolSchemaBytes = max(1_024, maximumToolSchemaBytes)
        self.maximumOutputTokensPerRequest =
            max(1, maximumOutputTokensPerRequest)
        self.maximumTotalTokensPerFlow = max(
            self.maximumOutputTokensPerRequest,
            maximumTotalTokensPerFlow)
        self.maximumIterationsPerFlow = max(1, maximumIterationsPerFlow)
        self.maximumToolUsesPerFlow = max(0, maximumToolUsesPerFlow)
        self.maximumParallelToolUses = max(0, maximumParallelToolUses)
        self.maximumRequestsPerMinute = max(1, maximumRequestsPerMinute)
        self.timeoutMilliseconds = max(100, timeoutMilliseconds)
        self.maximumStoredResultBytes = max(1_024, maximumStoredResultBytes)
    }
}

public struct MCPSamplingRequestPresentation: Sendable {
    public let requestID: RequestID
    public let flowID: MCPSamplingFlowID
    public let authority: MCPCallbackAuthorityContext
    public let parameters: CreateSamplingMessage.Parameters
    public let allowedInferenceBindings: Set<AgentInferenceBinding>

    public init(
        requestID: RequestID,
        flowID: MCPSamplingFlowID,
        authority: MCPCallbackAuthorityContext,
        parameters: CreateSamplingMessage.Parameters,
        allowedInferenceBindings: Set<AgentInferenceBinding>
    ) {
        self.requestID = requestID
        self.flowID = flowID
        self.authority = authority
        self.parameters = parameters
        self.allowedInferenceBindings = allowedInferenceBindings
    }
}

public enum MCPSamplingRequestReview: Sendable {
    case allow(
        parameters: CreateSamplingMessage.Parameters,
        inferenceBinding: AgentInferenceBinding)
    case deny(reasonCode: String)
    case cancel(reasonCode: String)
}

public struct MCPSamplingResultPresentation: Sendable {
    public let requestID: RequestID
    public let flowID: MCPSamplingFlowID
    public let authority: MCPCallbackAuthorityContext
    public let inferenceBinding: AgentInferenceBinding
    public let result: CreateSamplingMessage.Result

    public init(
        requestID: RequestID,
        flowID: MCPSamplingFlowID,
        authority: MCPCallbackAuthorityContext,
        inferenceBinding: AgentInferenceBinding,
        result: CreateSamplingMessage.Result
    ) {
        self.requestID = requestID
        self.flowID = flowID
        self.authority = authority
        self.inferenceBinding = inferenceBinding
        self.result = result
    }
}

public enum MCPSamplingResultReview: Sendable {
    case allow(CreateSamplingMessage.Result)
    case deny(reasonCode: String)
    case cancel(reasonCode: String)
}

/// UI/CLI human-in-the-loop surface. Request and completion review are
/// deliberately separate so an inference result is never returned to a server
/// merely because its input was approved.
public protocol MCPSamplingReviewService: Sendable {
    func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async throws -> MCPSamplingRequestReview

    func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async throws -> MCPSamplingResultReview
}

/// Provider-neutral inference bridge. Its input contains only the explicitly
/// approved MCP sampling request and exact binding. There is no AgentLoop,
/// Agent history, Intatis ToolRegistry, or other MCP-server context parameter.
public protocol MCPSamplingInferenceService: Sendable {
    func createSamplingMessage(
        parameters: CreateSamplingMessage.Parameters,
        inferenceBinding: AgentInferenceBinding
    ) async throws -> CreateSamplingMessage.Result
}

public struct MCPDenyAllSamplingReviewService: MCPSamplingReviewService {
    public init() {}

    public func reviewSamplingRequest(
        _ presentation: MCPSamplingRequestPresentation
    ) async throws -> MCPSamplingRequestReview {
        .deny(reasonCode: "sampling_default_deny")
    }

    public func reviewSamplingResult(
        _ presentation: MCPSamplingResultPresentation
    ) async throws -> MCPSamplingResultReview {
        .deny(reasonCode: "sampling_default_deny")
    }
}

public enum MCPSamplingBrokerError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedProfile
    case disabled
    case malformedRequest(String)
    case rateLimited
    case flowBudgetExceeded
    case inferenceBindingNotAllowed
    case denied
    case cancelled
    case timedOut
    case invalidModelResult(String)
    case resultTooLarge
    case persistenceFailed
    case inferenceFailed
    case reviewFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedProfile:
            return "MCP sampling is not available in this protocol profile."
        case .disabled:
            return "MCP sampling is disabled for this server authority."
        case .malformedRequest(let reason):
            return "The MCP sampling request is invalid: \(reason)"
        case .rateLimited:
            return "The MCP sampling request rate limit was exceeded."
        case .flowBudgetExceeded:
            return "The MCP sampling flow exceeded its hard budget."
        case .inferenceBindingNotAllowed:
            return "The selected inference binding is not allowed for MCP sampling."
        case .denied:
            return "The MCP sampling request was denied."
        case .cancelled:
            return "The MCP sampling request was cancelled."
        case .timedOut:
            return "The MCP sampling request timed out."
        case .invalidModelResult(let reason):
            return "The MCP sampling model result is invalid: \(reason)"
        case .resultTooLarge:
            return "The MCP sampling result exceeds the protected payload limit."
        case .persistenceFailed:
            return "The MCP sampling lifecycle could not be persisted."
        case .inferenceFailed:
            return "The isolated MCP sampling inference request failed."
        case .reviewFailed:
            return "The MCP sampling review could not be completed."
        }
    }
}

/// Independent sampling state machine. It cannot invoke tools. Tool-use blocks
/// are returned to the requesting server, which remains responsible for
/// execution and for supplying a later, balanced tool-result-only user message.
public actor MCPSamplingBroker {
    private struct FlowBudget: Sendable {
        var requests: Int
        var reservedTokens: Int
        var returnedToolUses: Int
        var lastActivity: Date
    }

    private let authority: MCPCallbackAuthorityContext
    private let policy: MCPSamplingPolicy
    private let reviewer: any MCPSamplingReviewService
    private let inference: any MCPSamplingInferenceService
    private let events: any MCPBrokerEventSink
    private let payloadStore: any MCPBrokerPayloadStore
    private var recentRequests: [Date] = []
    private var flowBudgets: [MCPSamplingFlowID: FlowBudget] = [:]

    public init(
        authority: MCPCallbackAuthorityContext,
        policy: MCPSamplingPolicy,
        reviewer: any MCPSamplingReviewService,
        inference: any MCPSamplingInferenceService,
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore
    ) {
        self.authority = authority
        self.policy = policy
        self.reviewer = reviewer
        self.inference = inference
        self.events = events
        self.payloadStore = payloadStore
    }

    public func handle(
        _ parameters: CreateSamplingMessage.Parameters,
        flowID: MCPSamplingFlowID = .new(),
        correlation: MCPEventCorrelation = .init(),
        now: Date = Date()
    ) async throws -> CreateSamplingMessage.Result {
        let requestID = RequestID.new()
        let fingerprint: MCPPayloadFingerprint
        do {
            fingerprint = try Self.fingerprint(parameters)
            try await events.appendMCPBrokerEvent(.mcpSamplingRequested(.init(
                requestID: requestID,
                server: authority.server,
                connectionGeneration: authority.connectionGeneration,
                request: fingerprint,
                maxOutputTokens: parameters.maxTokens,
                correlation: correlation)))
        } catch {
            throw MCPSamplingBrokerError.persistenceFailed
        }

        do {
            guard authority.profile == .standardExtended else {
                throw MCPSamplingBrokerError.unsupportedProfile
            }
            guard policy.enabled else {
                throw MCPSamplingBrokerError.disabled
            }
            try Self.validate(parameters, policy: policy)
            try admitRateAndFlow(
                flowID: flowID,
                requestedTokens: parameters.maxTokens,
                now: now)
        } catch let error as MCPSamplingBrokerError {
            try await settleRejectedRequest(
                requestID: requestID,
                error: error)
            throw error
        } catch {
            let wrapped = MCPSamplingBrokerError.malformedRequest(
                "request validation failed")
            try await settleRejectedRequest(
                requestID: requestID,
                error: wrapped)
            throw wrapped
        }

        let requestReview: MCPSamplingRequestReview
        do {
            requestReview = try await reviewer.reviewSamplingRequest(.init(
                requestID: requestID,
                flowID: flowID,
                authority: authority,
                parameters: parameters,
                allowedInferenceBindings: policy.allowedInferenceBindings))
        } catch {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_review_failed",
                error: .reviewFailed)
            throw MCPSamplingBrokerError.reviewFailed
        }

        let approvedParameters: CreateSamplingMessage.Parameters
        let binding: AgentInferenceBinding
        switch requestReview {
        case .allow(let edited, let selectedBinding):
            guard policy.allowedInferenceBindings.contains(selectedBinding) else {
                try await settleRejectedRequest(
                    requestID: requestID,
                    error: .inferenceBindingNotAllowed)
                throw MCPSamplingBrokerError.inferenceBindingNotAllowed
            }
            do {
                try Self.validate(edited, policy: policy)
            } catch {
                let wrapped = (error as? MCPSamplingBrokerError)
                    ?? .malformedRequest("edited request validation failed")
                try await settleRejectedRequest(
                    requestID: requestID,
                    error: wrapped)
                throw wrapped
            }
            approvedParameters = edited
            binding = selectedBinding
            try await appendDecision(
                requestID: requestID,
                decision: .allow,
                source: .user,
                reasonCode: "sampling_user_approved")
        case .deny(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .deny,
                source: .user,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .denied)
            throw MCPSamplingBrokerError.denied
        case .cancel(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .cancel,
                source: .user,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .cancelled)
            throw MCPSamplingBrokerError.cancelled
        }

        let generated: CreateSamplingMessage.Result
        do {
            generated = try await MCPCallbackDeadline.run(
                timeoutMilliseconds: policy.timeoutMilliseconds
            ) {
                try await self.inference.createSamplingMessage(
                    parameters: approvedParameters,
                    inferenceBinding: binding)
            }
        } catch is MCPCallbackDeadlineError {
            try await settleFailure(
                requestID: requestID,
                status: .timedOut,
                code: "sampling_timeout",
                error: .timedOut)
            throw MCPSamplingBrokerError.timedOut
        } catch is CancellationError {
            try await settleFailure(
                requestID: requestID,
                status: .cancelled,
                code: "sampling_cancelled",
                error: .cancelled)
            throw MCPSamplingBrokerError.cancelled
        } catch {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_inference_failed",
                error: .inferenceFailed)
            throw MCPSamplingBrokerError.inferenceFailed
        }

        do {
            let returnedToolUses = try Self.validate(
                generated,
                request: approvedParameters,
                policy: policy)
            try consumeReturnedToolUses(
                returnedToolUses,
                flowID: flowID,
                now: now)
        } catch let error as MCPSamplingBrokerError {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_invalid_result",
                error: error)
            throw error
        } catch {
            let wrapped = MCPSamplingBrokerError.invalidModelResult(
                "result validation failed")
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_invalid_result",
                error: wrapped)
            throw wrapped
        }

        let resultReview: MCPSamplingResultReview
        do {
            resultReview = try await reviewer.reviewSamplingResult(.init(
                requestID: requestID,
                flowID: flowID,
                authority: authority,
                inferenceBinding: binding,
                result: generated))
        } catch {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_result_review_failed",
                error: .reviewFailed)
            throw MCPSamplingBrokerError.reviewFailed
        }

        let approvedResult: CreateSamplingMessage.Result
        switch resultReview {
        case .allow(let edited):
            do {
                _ = try Self.validate(
                    edited,
                    request: approvedParameters,
                    policy: policy)
            } catch {
                let wrapped = (error as? MCPSamplingBrokerError)
                    ?? .invalidModelResult("edited result validation failed")
                try await settleFailure(
                    requestID: requestID,
                    status: .failed,
                    code: "sampling_invalid_reviewed_result",
                    error: wrapped)
                throw wrapped
            }
            approvedResult = edited
        case .deny(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .deny,
                source: .user,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .denied)
            throw MCPSamplingBrokerError.denied
        case .cancel(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .cancel,
                source: .user,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .cancelled)
            throw MCPSamplingBrokerError.cancelled
        }

        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(approvedResult)
        } catch {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_result_encoding_failed",
                error: .invalidModelResult("result encoding failed"))
            throw MCPSamplingBrokerError.invalidModelResult(
                "result encoding failed")
        }
        guard encoded.count <= policy.maximumStoredResultBytes else {
            try await settleFailure(
                requestID: requestID,
                status: .failed,
                code: "sampling_result_too_large",
                error: .resultTooLarge)
            throw MCPSamplingBrokerError.resultTooLarge
        }

        let resultReference: MCPResultReference
        do {
            resultReference = try await payloadStore.store(
                encoded,
                scopeFingerprint: payloadScope(
                    requestID: requestID,
                    flowID: flowID))
            try await events.appendMCPBrokerEvent(.mcpSamplingSettled(.init(
                requestID: requestID,
                status: .succeeded,
                resultReference: resultReference)))
        } catch {
            throw MCPSamplingBrokerError.persistenceFailed
        }
        return approvedResult
    }

    private func admitRateAndFlow(
        flowID: MCPSamplingFlowID,
        requestedTokens: Int,
        now: Date
    ) throws {
        let minuteAgo = now.addingTimeInterval(-60)
        recentRequests.removeAll { $0 < minuteAgo }
        guard recentRequests.count < policy.maximumRequestsPerMinute else {
            throw MCPSamplingBrokerError.rateLimited
        }
        recentRequests.append(now)

        // Flow budgets are live runtime state. Old idle entries can be removed;
        // durable facts remain in EventLog and cold restore never resumes them.
        let retentionCutoff = now.addingTimeInterval(-24 * 60 * 60)
        flowBudgets = flowBudgets.filter { $0.value.lastActivity >= retentionCutoff }

        var budget = flowBudgets[flowID] ?? FlowBudget(
            requests: 0,
            reservedTokens: 0,
            returnedToolUses: 0,
            lastActivity: now)
        guard budget.requests < policy.maximumIterationsPerFlow,
              budget.reservedTokens <=
                policy.maximumTotalTokensPerFlow - requestedTokens else {
            throw MCPSamplingBrokerError.flowBudgetExceeded
        }
        budget.requests += 1
        budget.reservedTokens += requestedTokens
        budget.lastActivity = now
        flowBudgets[flowID] = budget
    }

    private func consumeReturnedToolUses(
        _ count: Int,
        flowID: MCPSamplingFlowID,
        now: Date
    ) throws {
        guard var budget = flowBudgets[flowID] else {
            throw MCPSamplingBrokerError.flowBudgetExceeded
        }
        guard budget.returnedToolUses <=
                policy.maximumToolUsesPerFlow - count else {
            throw MCPSamplingBrokerError.flowBudgetExceeded
        }
        budget.returnedToolUses += count
        budget.lastActivity = now
        flowBudgets[flowID] = budget
    }

    private func settleRejectedRequest(
        requestID: RequestID,
        error: MCPSamplingBrokerError
    ) async throws {
        let reason: String
        switch error {
        case .unsupportedProfile:
            reason = "sampling_profile_not_supported"
        case .disabled:
            reason = "sampling_disabled"
        case .rateLimited:
            reason = "sampling_rate_limited"
        case .flowBudgetExceeded:
            reason = "sampling_budget_exceeded"
        case .inferenceBindingNotAllowed:
            reason = "sampling_binding_not_allowed"
        default:
            reason = "sampling_request_rejected"
        }
        try await appendDecision(
            requestID: requestID,
            decision: .deny,
            source: .deterministicPolicy,
            reasonCode: reason)
        try await appendTerminal(
            requestID: requestID,
            status: .denied,
            diagnostic: .init(
                code: reason,
                summary: error.localizedDescription))
    }

    private func settleFailure(
        requestID: RequestID,
        status: MCPDurableTerminalStatus,
        code: String,
        error: MCPSamplingBrokerError
    ) async throws {
        try await appendTerminal(
            requestID: requestID,
            status: status,
            diagnostic: .init(
                code: code,
                summary: error.localizedDescription))
    }

    private func appendDecision(
        requestID: RequestID,
        decision: MCPBrokerDecision,
        source: MCPBrokerDecisionSource,
        reasonCode: String
    ) async throws {
        do {
            try await events.appendMCPBrokerEvent(.mcpSamplingDecided(.init(
                requestID: requestID,
                decision: decision,
                source: source,
                reasonCode: reasonCode)))
        } catch {
            throw MCPSamplingBrokerError.persistenceFailed
        }
    }

    private func appendTerminal(
        requestID: RequestID,
        status: MCPDurableTerminalStatus,
        diagnostic: MCPDiagnosticSummary? = nil
    ) async throws {
        do {
            try await events.appendMCPBrokerEvent(.mcpSamplingSettled(.init(
                requestID: requestID,
                status: status,
                diagnostic: diagnostic)))
        } catch {
            throw MCPSamplingBrokerError.persistenceFailed
        }
    }

    private func payloadScope(
        requestID: RequestID,
        flowID: MCPSamplingFlowID
    ) -> String {
        [
            "sampling",
            authority.server.serverID.rawValue,
            authority.server.serverRevision.rawValue,
            authority.connectionGeneration.rawValue,
            authority.authorityFingerprint,
            flowID.rawValue,
            requestID.rawValue,
        ].joined(separator: "\u{1f}")
    }

    private static func safeReasonCode(_ value: String) -> String {
        let normalized = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "_" || character == "-" {
                return character
            }
            return "_"
        }
        let result = String(normalized.prefix(80))
        return result.isEmpty ? "user_decision" : result
    }

    private static func fingerprint<T: Encodable>(
        _ value: T
    ) throws -> MCPPayloadFingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return MCPPayloadFingerprint(
            sha256: MCPConfigurationCanonical.sha256(data),
            characterCount: String(decoding: data, as: UTF8.self).count)
    }

    private static func validate(
        _ parameters: CreateSamplingMessage.Parameters,
        policy: MCPSamplingPolicy
    ) throws {
        let data = try JSONEncoder().encode(parameters)
        guard data.count <= policy.maximumRequestBytes else {
            throw MCPSamplingBrokerError.malformedRequest(
                "encoded request exceeds the size limit")
        }
        guard parameters.maxTokens > 0,
              parameters.maxTokens <=
                policy.maximumOutputTokensPerRequest else {
            throw MCPSamplingBrokerError.malformedRequest(
                "maxTokens is outside the allowed range")
        }
        guard parameters.messages.count <= policy.maximumMessages else {
            throw MCPSamplingBrokerError.malformedRequest(
                "message count exceeds the limit")
        }
        if let systemPrompt = parameters.systemPrompt {
            guard systemPrompt.utf8.count <=
                    policy.maximumSystemPromptBytes else {
                throw MCPSamplingBrokerError.malformedRequest(
                    "system prompt exceeds the size limit")
            }
        }
        if let includeContext = parameters.includeContext,
           includeContext != .none {
            throw MCPSamplingBrokerError.malformedRequest(
                "deprecated MCP context inclusion was not advertised")
        }
        let tools = parameters.tools ?? []
        guard tools.count <= policy.maximumTools else {
            throw MCPSamplingBrokerError.malformedRequest(
                "tool count exceeds the limit")
        }
        let toolData = try JSONEncoder().encode(tools)
        guard toolData.count <= policy.maximumToolSchemaBytes else {
            throw MCPSamplingBrokerError.malformedRequest(
                "tool schemas exceed the size limit")
        }
        if parameters.toolChoice?.mode == .required, tools.isEmpty {
            throw MCPSamplingBrokerError.malformedRequest(
                "required tool choice has no tools")
        }
        if parameters.toolChoice?.mode ==
            CreateSamplingMessage.ToolChoice.Mode.none, !tools.isEmpty {
            // Tools may be supplied with `none`; the broker validates that no
            // tool-use block is returned. This remains a valid MCP request.
        }
        try validateToolHistory(parameters.messages)
    }

    private static func validateToolHistory(
        _ messages: [Sampling.Message]
    ) throws {
        var allUseIDs: Set<String> = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            let blocks = message.content.asArray
            var useIDs: [String] = []
            var containsResult = false
            for block in blocks {
                switch block {
                case .toolUse(let use):
                    guard message.role == .assistant,
                          !use.id.isEmpty,
                          allUseIDs.insert(use.id).inserted else {
                        throw MCPSamplingBrokerError.malformedRequest(
                            "tool-use IDs must be unique assistant content")
                    }
                    useIDs.append(use.id)
                case .toolResult:
                    containsResult = true
                case .text, .image, .audio:
                    break
                }
            }
            guard !containsResult else {
                throw MCPSamplingBrokerError.malformedRequest(
                    "tool results must immediately follow assistant tool uses")
            }

            if !useIDs.isEmpty {
                guard index + 1 < messages.count else {
                    throw MCPSamplingBrokerError.malformedRequest(
                        "sampling history has unresolved tool uses")
                }
                let resultMessage = messages[index + 1]
                let resultBlocks = resultMessage.content.asArray
                guard resultMessage.role == .user,
                      !resultBlocks.isEmpty,
                      resultBlocks.allSatisfy({
                          if case .toolResult = $0 { return true }
                          return false
                      }) else {
                    throw MCPSamplingBrokerError.malformedRequest(
                        "assistant tool uses must be followed by a pure tool-result user message")
                }
                var resultIDs: Set<String> = []
                for block in resultBlocks {
                    guard case .toolResult(let result) = block,
                          !result.toolUseId.isEmpty,
                          resultIDs.insert(result.toolUseId).inserted else {
                        throw MCPSamplingBrokerError.malformedRequest(
                            "tool result IDs must be unique")
                    }
                }
                guard resultIDs == Set(useIDs) else {
                    throw MCPSamplingBrokerError.malformedRequest(
                        "tool results must exactly balance the preceding tool uses")
                }
                index += 2
            } else {
                index += 1
            }
        }
    }

    @discardableResult
    private static func validate(
        _ result: CreateSamplingMessage.Result,
        request: CreateSamplingMessage.Parameters,
        policy: MCPSamplingPolicy
    ) throws -> Int {
        guard result.role == .assistant else {
            throw MCPSamplingBrokerError.invalidModelResult(
                "result role must be assistant")
        }
        let availableTools = Set((request.tools ?? []).map(\.name))
        let toolByName = Dictionary(
            uniqueKeysWithValues: (request.tools ?? []).map { ($0.name, $0) })
        var useIDs: Set<String> = []
        var toolUseCount = 0
        for block in result.content.asArray {
            switch block {
            case .toolUse(let use):
                guard !use.id.isEmpty,
                      useIDs.insert(use.id).inserted,
                      availableTools.contains(use.name) else {
                    throw MCPSamplingBrokerError.invalidModelResult(
                        "tool use is duplicate or names an unavailable tool")
                }
                if let tool = toolByName[use.name] {
                    do {
                        try MCPJSONSchema.validate(
                            .object(try use.input.mapValues(
                                MCPJSONValueBridge.fromSDK)),
                            against: try MCPJSONValueBridge.fromSDK(
                                tool.inputSchema))
                    } catch {
                        throw MCPSamplingBrokerError.invalidModelResult(
                            "tool input does not match the advertised schema")
                    }
                }
                toolUseCount += 1
            case .toolResult:
                throw MCPSamplingBrokerError.invalidModelResult(
                    "assistant result cannot contain tool-result content")
            case .text, .image, .audio:
                break
            }
        }
        guard toolUseCount <= policy.maximumParallelToolUses else {
            throw MCPSamplingBrokerError.invalidModelResult(
                "parallel tool-use count exceeds the limit")
        }
        let choice = request.toolChoice?.mode ?? .auto
        if choice == .none, toolUseCount != 0 {
            throw MCPSamplingBrokerError.invalidModelResult(
                "tool choice none returned a tool use")
        }
        if choice == .required, toolUseCount == 0 {
            throw MCPSamplingBrokerError.invalidModelResult(
                "required tool choice returned no tool use")
        }
        if toolUseCount > 0, result.stopReason != .toolUse {
            throw MCPSamplingBrokerError.invalidModelResult(
                "tool-use content requires stopReason toolUse")
        }
        if toolUseCount == 0, result.stopReason == .toolUse {
            throw MCPSamplingBrokerError.invalidModelResult(
                "stopReason toolUse requires tool-use content")
        }
        return toolUseCount
    }
}

enum MCPCallbackDeadlineError: Error {
    case timedOut
}

enum MCPCallbackDeadline {
    static func run<Value: Sendable>(
        timeoutMilliseconds: Int,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                try Task.checkCancellation()
                throw MCPCallbackDeadlineError.timedOut
            }
            guard let first = try await group.next() else {
                throw MCPCallbackDeadlineError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}
