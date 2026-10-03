import Foundation
import IntatisCore
import IntatisProtocol
import MCP

public struct MCPElicitationPolicy: Equatable, Sendable {
    public let formEnabled: Bool
    public let urlEnabled: Bool
    public let maximumRequestBytes: Int
    public let maximumMessageBytes: Int
    public let maximumFormProperties: Int
    public let maximumStringResponseBytes: Int
    public let maximumArrayItems: Int
    public let maximumURLBytes: Int
    public let allowedURLOrigins: Set<String>
    public let maximumRequestsPerMinute: Int
    public let timeoutMilliseconds: Int
    public let pendingURLTTLSeconds: TimeInterval
    public let maximumStoredResultBytes: Int

    public init(
        formEnabled: Bool = false,
        urlEnabled: Bool = false,
        maximumRequestBytes: Int = 256 * 1_024,
        maximumMessageBytes: Int = 32 * 1_024,
        maximumFormProperties: Int = 64,
        maximumStringResponseBytes: Int = 64 * 1_024,
        maximumArrayItems: Int = 128,
        maximumURLBytes: Int = 8 * 1_024,
        allowedURLOrigins: Set<String> = [],
        maximumRequestsPerMinute: Int = 30,
        timeoutMilliseconds: Int = 10 * 60 * 1_000,
        pendingURLTTLSeconds: TimeInterval = 24 * 60 * 60,
        maximumStoredResultBytes: Int = 256 * 1_024
    ) {
        self.formEnabled = formEnabled
        self.urlEnabled = urlEnabled
        self.maximumRequestBytes = max(1_024, maximumRequestBytes)
        self.maximumMessageBytes = max(1_024, maximumMessageBytes)
        self.maximumFormProperties = max(1, maximumFormProperties)
        self.maximumStringResponseBytes = max(
            1_024,
            maximumStringResponseBytes)
        self.maximumArrayItems = max(1, maximumArrayItems)
        self.maximumURLBytes = max(256, maximumURLBytes)
        self.allowedURLOrigins = allowedURLOrigins
        self.maximumRequestsPerMinute = max(1, maximumRequestsPerMinute)
        self.timeoutMilliseconds = max(100, timeoutMilliseconds)
        self.pendingURLTTLSeconds = max(60, pendingURLTTLSeconds)
        self.maximumStoredResultBytes = max(1_024, maximumStoredResultBytes)
    }
}

public struct MCPElicitationPresentation: Sendable {
    public let requestID: RequestID
    public let authority: MCPCallbackAuthorityContext
    public let parameters: CreateElicitation.Parameters
    /// Present only for URL mode. This is parsed locally; no URL prefetch or
    /// metadata request is performed.
    public let highlightedHost: String?
    public let suspiciousPunycodeHost: Bool

    public init(
        requestID: RequestID,
        authority: MCPCallbackAuthorityContext,
        parameters: CreateElicitation.Parameters,
        highlightedHost: String? = nil,
        suspiciousPunycodeHost: Bool = false
    ) {
        self.requestID = requestID
        self.authority = authority
        self.parameters = parameters
        self.highlightedHost = highlightedHost
        self.suspiciousPunycodeHost = suspiciousPunycodeHost
    }
}

public enum MCPElicitationReview: Sendable {
    /// Form content must match the requested schema. URL acceptance must carry
    /// nil content because all external data stays out-of-band.
    case accept(content: [String: Value]?)
    case decline(reasonCode: String)
    case cancel(reasonCode: String)
}

/// UI/CLI adapter responsible for visibly presenting the requesting server,
/// full form/URL, decline/cancel controls, and secure external navigation.
public protocol MCPElicitationReviewService: Sendable {
    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview
}

public struct MCPDenyAllElicitationReviewService:
    MCPElicitationReviewService
{
    public init() {}

    public func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview {
        .decline(reasonCode: "elicitation_default_deny")
    }
}

public enum MCPElicitationBrokerError: Error, Equatable, LocalizedError,
    Sendable
{
    case unsupportedMode
    case disabled
    case malformedRequest(String)
    case sensitiveFormField(String)
    case unsafeURL
    case URLOriginNotAllowed
    case duplicateElicitationID
    case invalidResponse(String)
    case rateLimited
    case declined
    case cancelled
    case timedOut
    case resultTooLarge
    case persistenceFailed
    case reviewFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "The elicitation mode is unavailable in this MCP profile."
        case .disabled:
            return "MCP elicitation is disabled for this server authority."
        case .malformedRequest(let reason):
            return "The MCP elicitation request is invalid: \(reason)"
        case .sensitiveFormField(let name):
            return "Form elicitation cannot request sensitive field \(name)."
        case .unsafeURL:
            return "The URL elicitation target is unsafe."
        case .URLOriginNotAllowed:
            return "The URL elicitation origin is not allowed."
        case .duplicateElicitationID:
            return "The URL elicitation identifier is already active."
        case .invalidResponse(let reason):
            return "The elicitation response is invalid: \(reason)"
        case .rateLimited:
            return "The MCP elicitation request rate limit was exceeded."
        case .declined:
            return "The MCP elicitation request was declined."
        case .cancelled:
            return "The MCP elicitation request was cancelled."
        case .timedOut:
            return "The MCP elicitation request timed out."
        case .resultTooLarge:
            return "The elicitation result exceeds the protected payload limit."
        case .persistenceFailed:
            return "The MCP elicitation lifecycle could not be persisted."
        case .reviewFailed:
            return "The MCP elicitation review could not be completed."
        }
    }
}

public enum MCPURLElicitationCompletionState: Equatable, Sendable {
    case pending
    case completed
}

/// Independent form/URL elicitation broker. It never asks a model to fill a
/// form, never fetches an elicitation URL, and never receives third-party
/// credentials entered in the external browser flow.
public actor MCPElicitationBroker {
    private struct PendingURL: Sendable {
        var state: MCPURLElicitationCompletionState
        let acceptedAt: Date
    }

    private let authority: MCPCallbackAuthorityContext
    private let policy: MCPElicitationPolicy
    private let reviewer: any MCPElicitationReviewService
    private let events: any MCPBrokerEventSink
    private let payloadStore: any MCPBrokerPayloadStore
    private var recentRequests: [Date] = []
    private var pendingURLs: [String: PendingURL] = [:]

    public init(
        authority: MCPCallbackAuthorityContext,
        policy: MCPElicitationPolicy,
        reviewer: any MCPElicitationReviewService,
        events: any MCPBrokerEventSink,
        payloadStore: any MCPBrokerPayloadStore
    ) {
        self.authority = authority
        self.policy = policy
        self.reviewer = reviewer
        self.events = events
        self.payloadStore = payloadStore
    }

    public func handle(
        _ parameters: CreateElicitation.Parameters,
        correlation: MCPEventCorrelation = .init(),
        now: Date = Date()
    ) async throws -> CreateElicitation.Result {
        let requestID = RequestID.new()
        let mode = Self.mode(parameters)
        let requestFingerprint: MCPPayloadFingerprint
        do {
            requestFingerprint = try Self.fingerprint(parameters)
            try await events.appendMCPBrokerEvent(
                .mcpElicitationRequested(.init(
                    requestID: requestID,
                    server: authority.server,
                    connectionGeneration: authority.connectionGeneration,
                    mode: mode,
                    request: requestFingerprint,
                    correlation: correlation)))
        } catch {
            throw MCPElicitationBrokerError.persistenceFailed
        }

        let URLPresentation: (host: String?, punycode: Bool)
        do {
            try admitRate(now: now)
            URLPresentation = try Self.validate(
                parameters,
                authority: authority,
                policy: policy)
            if case .url(let URLParameters) = parameters {
                expirePendingURLs(now: now)
                guard pendingURLs[URLParameters.elicitationId] == nil else {
                    throw MCPElicitationBrokerError
                        .duplicateElicitationID
                }
            }
        } catch let error as MCPElicitationBrokerError {
            try await settleRejected(
                requestID: requestID,
                error: error)
            throw error
        } catch {
            let wrapped = MCPElicitationBrokerError.malformedRequest(
                "request validation failed")
            try await settleRejected(
                requestID: requestID,
                error: wrapped)
            throw wrapped
        }

        let review: MCPElicitationReview
        do {
            review = try await MCPCallbackDeadline.run(
                timeoutMilliseconds: policy.timeoutMilliseconds
            ) {
                try await self.reviewer.reviewElicitation(.init(
                    requestID: requestID,
                    authority: self.authority,
                    parameters: parameters,
                    highlightedHost: URLPresentation.host,
                    suspiciousPunycodeHost: URLPresentation.punycode))
            }
        } catch is MCPCallbackDeadlineError {
            try await appendTerminal(
                requestID: requestID,
                status: .timedOut,
                diagnostic: .init(
                    code: "elicitation_timeout",
                    summary: MCPElicitationBrokerError.timedOut
                        .localizedDescription))
            throw MCPElicitationBrokerError.timedOut
        } catch is CancellationError {
            try await appendTerminal(
                requestID: requestID,
                status: .cancelled,
                diagnostic: .init(
                    code: "elicitation_cancelled",
                    summary: MCPElicitationBrokerError.cancelled
                        .localizedDescription))
            throw MCPElicitationBrokerError.cancelled
        } catch {
            try await appendTerminal(
                requestID: requestID,
                status: .failed,
                diagnostic: .init(
                    code: "elicitation_review_failed",
                    summary: MCPElicitationBrokerError.reviewFailed
                        .localizedDescription))
            throw MCPElicitationBrokerError.reviewFailed
        }

        switch review {
        case .decline(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .deny,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .denied)
            throw MCPElicitationBrokerError.declined
        case .cancel(let reasonCode):
            try await appendDecision(
                requestID: requestID,
                decision: .cancel,
                reasonCode: Self.safeReasonCode(reasonCode))
            try await appendTerminal(
                requestID: requestID,
                status: .cancelled)
            throw MCPElicitationBrokerError.cancelled
        case .accept(let content):
            let result: CreateElicitation.Result
            switch parameters {
            case .form(let form):
                guard let content else {
                    let error = MCPElicitationBrokerError.invalidResponse(
                        "accepted form has no content")
                    try await settleInvalidResponse(
                        requestID: requestID,
                        error: error)
                    throw error
                }
                do {
                    try MCPFormSchemaValidator.validateResponse(
                        content,
                        schema: form.requestedSchema,
                        policy: policy)
                } catch let error as MCPElicitationBrokerError {
                    try await settleInvalidResponse(
                        requestID: requestID,
                        error: error)
                    throw error
                } catch {
                    let wrapped = MCPElicitationBrokerError.invalidResponse(
                        "schema validation failed")
                    try await settleInvalidResponse(
                        requestID: requestID,
                        error: wrapped)
                    throw wrapped
                }
                result = .init(action: .accept, content: content)
            case .url(let URLParameters):
                guard content == nil else {
                    let error = MCPElicitationBrokerError.invalidResponse(
                        "URL elicitation cannot return in-band content")
                    try await settleInvalidResponse(
                        requestID: requestID,
                        error: error)
                    throw error
                }
                pendingURLs[URLParameters.elicitationId] = PendingURL(
                    state: .pending,
                    acceptedAt: now)
                result = .init(action: .accept)
            }

            try await appendDecision(
                requestID: requestID,
                decision: .allow,
                reasonCode: "elicitation_user_approved")
            let encoded = try JSONEncoder().encode(result)
            guard encoded.count <= policy.maximumStoredResultBytes else {
                try await appendTerminal(
                    requestID: requestID,
                    status: .failed,
                    diagnostic: .init(
                        code: "elicitation_result_too_large",
                        summary: MCPElicitationBrokerError.resultTooLarge
                            .localizedDescription))
                throw MCPElicitationBrokerError.resultTooLarge
            }
            do {
                let reference = try await payloadStore.store(
                    encoded,
                    scopeFingerprint: payloadScope(
                        requestID: requestID))
                try await events.appendMCPBrokerEvent(
                    .mcpElicitationSettled(.init(
                        requestID: requestID,
                        status: .succeeded,
                        resultReference: reference)))
            } catch {
                throw MCPElicitationBrokerError.persistenceFailed
            }
            return result
        }
    }

    /// Handles `notifications/elicitation/complete`. Unknown, expired, or
    /// already-completed IDs are ignored as required by the specification.
    @discardableResult
    public func markURLCompleted(
        elicitationID: String,
        now: Date = Date()
    ) -> Bool {
        expirePendingURLs(now: now)
        guard var pending = pendingURLs[elicitationID],
              pending.state == .pending else {
            return false
        }
        pending.state = .completed
        pendingURLs[elicitationID] = pending
        return true
    }

    public func URLCompletionState(
        elicitationID: String,
        now: Date = Date()
    ) -> MCPURLElicitationCompletionState? {
        expirePendingURLs(now: now)
        return pendingURLs[elicitationID]?.state
    }

    /// Disconnect/session-stop cleanup. It does not claim an external browser
    /// flow completed and does not trigger automatic replay of any MCP request.
    public func retireGeneration() {
        pendingURLs.removeAll(keepingCapacity: false)
        recentRequests.removeAll(keepingCapacity: false)
    }

    private func admitRate(now: Date) throws {
        let cutoff = now.addingTimeInterval(-60)
        recentRequests.removeAll { $0 < cutoff }
        guard recentRequests.count < policy.maximumRequestsPerMinute else {
            throw MCPElicitationBrokerError.rateLimited
        }
        recentRequests.append(now)
    }

    private func expirePendingURLs(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.pendingURLTTLSeconds)
        pendingURLs = pendingURLs.filter { $0.value.acceptedAt >= cutoff }
    }

    private func settleRejected(
        requestID: RequestID,
        error: MCPElicitationBrokerError
    ) async throws {
        let reason: String
        switch error {
        case .unsupportedMode:
            reason = "elicitation_mode_not_supported"
        case .disabled:
            reason = "elicitation_disabled"
        case .sensitiveFormField:
            reason = "elicitation_sensitive_form"
        case .unsafeURL:
            reason = "elicitation_unsafe_url"
        case .URLOriginNotAllowed:
            reason = "elicitation_url_origin_denied"
        case .rateLimited:
            reason = "elicitation_rate_limited"
        default:
            reason = "elicitation_request_rejected"
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

    private func settleInvalidResponse(
        requestID: RequestID,
        error: MCPElicitationBrokerError
    ) async throws {
        try await appendTerminal(
            requestID: requestID,
            status: .failed,
            diagnostic: .init(
                code: "elicitation_invalid_response",
                summary: error.localizedDescription))
    }

    private func appendDecision(
        requestID: RequestID,
        decision: MCPBrokerDecision,
        source: MCPBrokerDecisionSource = .user,
        reasonCode: String
    ) async throws {
        do {
            try await events.appendMCPBrokerEvent(
                .mcpElicitationDecided(.init(
                    requestID: requestID,
                    decision: decision,
                    source: source,
                    reasonCode: reasonCode)))
        } catch {
            throw MCPElicitationBrokerError.persistenceFailed
        }
    }

    private func appendTerminal(
        requestID: RequestID,
        status: MCPDurableTerminalStatus,
        diagnostic: MCPDiagnosticSummary? = nil
    ) async throws {
        do {
            try await events.appendMCPBrokerEvent(
                .mcpElicitationSettled(.init(
                    requestID: requestID,
                    status: status,
                    diagnostic: diagnostic)))
        } catch {
            throw MCPElicitationBrokerError.persistenceFailed
        }
    }

    private func payloadScope(requestID: RequestID) -> String {
        [
            "elicitation",
            authority.server.serverID.rawValue,
            authority.server.serverRevision.rawValue,
            authority.connectionGeneration.rawValue,
            authority.authorityFingerprint,
            requestID.rawValue,
        ].joined(separator: "\u{1f}")
    }

    private static func mode(
        _ parameters: CreateElicitation.Parameters
    ) -> MCPElicitationMode {
        switch parameters {
        case .form:
            return .form
        case .url:
            return .url
        }
    }

    private static func validate(
        _ parameters: CreateElicitation.Parameters,
        authority: MCPCallbackAuthorityContext,
        policy: MCPElicitationPolicy
    ) throws -> (host: String?, punycode: Bool) {
        let encoded = try JSONEncoder().encode(parameters)
        guard encoded.count <= policy.maximumRequestBytes else {
            throw MCPElicitationBrokerError.malformedRequest(
                "encoded request exceeds the size limit")
        }
        switch parameters {
        case .form(let form):
            guard policy.formEnabled else {
                throw MCPElicitationBrokerError.disabled
            }
            guard form.message.utf8.count <= policy.maximumMessageBytes else {
                throw MCPElicitationBrokerError.malformedRequest(
                    "message exceeds the size limit")
            }
            if let sensitive = MCPFormSchemaValidator.sensitiveTerm(
                in: form.message) {
                throw MCPElicitationBrokerError.sensitiveFormField(
                    sensitive)
            }
            try MCPFormSchemaValidator.validateSchema(
                form.requestedSchema,
                policy: policy)
            return (nil, false)
        case .url(let URLParameters):
            guard authority.profile == .standardExtended else {
                throw MCPElicitationBrokerError.unsupportedMode
            }
            guard policy.urlEnabled else {
                throw MCPElicitationBrokerError.disabled
            }
            guard !URLParameters.elicitationId.isEmpty,
                  URLParameters.elicitationId.utf8.count <= 1_024,
                  URLParameters.message.utf8.count <=
                    policy.maximumMessageBytes,
                  URLParameters.url.utf8.count <= policy.maximumURLBytes,
                  let URL = URL(string: URLParameters.url),
                  URL.scheme?.lowercased() == "https",
                  URL.user == nil,
                  URL.password == nil,
                  let host = URL.host?.lowercased(),
                  !host.isEmpty else {
                throw MCPElicitationBrokerError.unsafeURL
            }
            let origin = try canonicalOrigin(URL)
            if !policy.allowedURLOrigins.isEmpty,
               !policy.allowedURLOrigins.contains(origin) {
                throw MCPElicitationBrokerError.URLOriginNotAllowed
            }
            guard URL.fragment == nil,
                  !containsSecretURLMaterial(URL) else {
                throw MCPElicitationBrokerError.unsafeURL
            }
            return (host, host.contains("xn--"))
        }
    }

    private static func canonicalOrigin(_ URL: URL) throws -> String {
        guard let scheme = URL.scheme?.lowercased(),
              let host = URL.host?.lowercased() else {
            throw MCPElicitationBrokerError.unsafeURL
        }
        let port = URL.port
        if port == nil || port == 443 {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port!)"
    }

    private static func containsSecretURLMaterial(_ URL: URL) -> Bool {
        let forbiddenNames: Set<String> = [
            "access_token", "refresh_token", "id_token", "api_key",
            "apikey", "password", "passwd", "secret", "authorization",
            "bearer",
        ]
        guard let components = URLComponents(
            url: URL,
            resolvingAgainstBaseURL: false) else {
            return true
        }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if forbiddenNames.contains(name) {
                return true
            }
            let value = item.value?.lowercased() ?? ""
            if value.hasPrefix("bearer ")
                || value.hasPrefix("sk-")
                || value.hasPrefix("ghp_")
                || value.hasPrefix("github_pat_") {
                return true
            }
        }
        return false
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
}

// MARK: - Restricted form schema validation

enum MCPFormSchemaValidator {
    private static let sensitiveTerms = [
        "password", "passcode", "passwd", "api key", "apikey",
        "access token", "refresh token", "id token", "secret",
        "credential", "private key", "seed phrase", "recovery phrase",
        "credit card", "card number", "cvv", "cvc", "bank account",
        "routing number",
    ]

    static func sensitiveTerm(in value: String) -> String? {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return sensitiveTerms.first { normalized.contains($0) }
    }

    static func validateSchema(
        _ schema: Elicitation.RequestSchema,
        policy: MCPElicitationPolicy
    ) throws {
        guard schema.properties.count <= policy.maximumFormProperties else {
            throw MCPElicitationBrokerError.malformedRequest(
                "form property count exceeds the limit")
        }
        let propertyNames = Set(schema.properties.keys)
        let required = Set(schema.required ?? [])
        guard required.isSubset(of: propertyNames) else {
            throw MCPElicitationBrokerError.malformedRequest(
                "required fields are not declared properties")
        }
        for (name, value) in schema.properties {
            guard !name.isEmpty, name.utf8.count <= 256,
                  case .object(let definition) = value else {
                throw MCPElicitationBrokerError.malformedRequest(
                    "form properties must be named schema objects")
            }
            let displayText = [
                name,
                definition["title"]?.stringValue ?? "",
                definition["description"]?.stringValue ?? "",
            ].joined(separator: " ")
            if let sensitive = sensitiveTerm(in: displayText) {
                throw MCPElicitationBrokerError.sensitiveFormField(
                    sensitive)
            }
            try validatePropertySchema(
                definition,
                policy: policy)
        }
    }

    static func validateResponse(
        _ response: [String: Value],
        schema: Elicitation.RequestSchema,
        policy: MCPElicitationPolicy
    ) throws {
        try validateSchema(schema, policy: policy)
        let definitions = schema.properties
        guard Set(response.keys).isSubset(of: Set(definitions.keys)) else {
            throw MCPElicitationBrokerError.invalidResponse(
                "response contains undeclared properties")
        }
        let required = Set(schema.required ?? [])
        guard required.isSubset(of: Set(response.keys)) else {
            throw MCPElicitationBrokerError.invalidResponse(
                "response is missing required properties")
        }
        for (name, value) in response {
            guard case .object(let definition) = definitions[name] else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "property schema is unavailable")
            }
            try validateValue(
                value,
                definition: definition,
                policy: policy)
        }
    }

    private static func validatePropertySchema(
        _ definition: [String: Value],
        policy: MCPElicitationPolicy
    ) throws {
        guard let type = definition["type"]?.stringValue else {
            throw MCPElicitationBrokerError.malformedRequest(
                "form property has no primitive type")
        }
        let common: Set<String> = [
            "type", "title", "description", "default",
        ]
        let allowed: Set<String>
        switch type {
        case "string":
            allowed = common.union([
                "minLength", "maxLength", "pattern", "format",
                "enum", "oneOf",
            ])
            if let format = definition["format"]?.stringValue {
                guard ["email", "uri", "date", "date-time"]
                    .contains(format) else {
                    throw MCPElicitationBrokerError.malformedRequest(
                        "unsupported string format")
                }
            }
            if let pattern = definition["pattern"]?.stringValue {
                guard pattern.utf8.count <= 1_024,
                      (try? NSRegularExpression(pattern: pattern)) != nil else {
                    throw MCPElicitationBrokerError.malformedRequest(
                        "invalid or oversized string pattern")
                }
            }
            try validateSingleSelect(definition)
        case "number", "integer":
            allowed = common.union(["minimum", "maximum"])
        case "boolean":
            allowed = common
        case "array":
            allowed = common.union(["minItems", "maxItems", "items"])
            try validateMultiSelect(definition, policy: policy)
        default:
            throw MCPElicitationBrokerError.malformedRequest(
                "nested or unsupported form property type")
        }
        guard Set(definition.keys).isSubset(of: allowed) else {
            throw MCPElicitationBrokerError.malformedRequest(
                "form property uses unsupported JSON Schema keywords")
        }
        if let defaultValue = definition["default"] {
            try validateValue(
                defaultValue,
                definition: definition,
                policy: policy,
                validatingDefault: true)
        }
    }

    private static func validateSingleSelect(
        _ definition: [String: Value]
    ) throws {
        if definition["enum"] != nil && definition["oneOf"] != nil {
            throw MCPElicitationBrokerError.malformedRequest(
                "string enum cannot use enum and oneOf together")
        }
        if let enumValue = definition["enum"] {
            guard case .array(let values) = enumValue,
                  !values.isEmpty,
                  values.count <= 256,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                throw MCPElicitationBrokerError.malformedRequest(
                    "string enum is invalid")
            }
        }
        if let oneOf = definition["oneOf"] {
            try validateTitledOptions(oneOf, key: "oneOf")
        }
    }

    private static func validateMultiSelect(
        _ definition: [String: Value],
        policy: MCPElicitationPolicy
    ) throws {
        guard case .object(let items)? = definition["items"] else {
            throw MCPElicitationBrokerError.malformedRequest(
                "array form property must declare enum items")
        }
        let allowedItemKeys: Set<String> = ["type", "enum", "anyOf"]
        guard Set(items.keys).isSubset(of: allowedItemKeys) else {
            throw MCPElicitationBrokerError.malformedRequest(
                "array items use unsupported schema keywords")
        }
        if let type = items["type"]?.stringValue, type != "string" {
            throw MCPElicitationBrokerError.malformedRequest(
                "multi-select items must be strings")
        }
        if items["enum"] != nil && items["anyOf"] != nil {
            throw MCPElicitationBrokerError.malformedRequest(
                "multi-select cannot use enum and anyOf together")
        }
        if let values = items["enum"] {
            guard case .array(let options) = values,
                  !options.isEmpty,
                  options.count <= policy.maximumArrayItems,
                  options.allSatisfy({ $0.stringValue != nil }) else {
                throw MCPElicitationBrokerError.malformedRequest(
                    "multi-select enum is invalid")
            }
        } else if let anyOf = items["anyOf"] {
            try validateTitledOptions(anyOf, key: "anyOf")
        } else {
            throw MCPElicitationBrokerError.malformedRequest(
                "multi-select must declare enum or anyOf")
        }
    }

    private static func validateTitledOptions(
        _ value: Value,
        key: String
    ) throws {
        guard case .array(let options) = value,
              !options.isEmpty,
              options.count <= 256 else {
            throw MCPElicitationBrokerError.malformedRequest(
                "\(key) options are invalid")
        }
        for option in options {
            guard case .object(let object) = option,
                  Set(object.keys).isSubset(of: ["const", "title"]),
                  object["const"]?.stringValue != nil,
                  object["title"]?.stringValue != nil else {
                throw MCPElicitationBrokerError.malformedRequest(
                    "\(key) option is invalid")
            }
        }
    }

    private static func validateValue(
        _ value: Value,
        definition: [String: Value],
        policy: MCPElicitationPolicy,
        validatingDefault: Bool = false
    ) throws {
        guard let type = definition["type"]?.stringValue else {
            throw MCPElicitationBrokerError.invalidResponse(
                "property type is unavailable")
        }
        switch type {
        case "string":
            guard let string = value.stringValue,
                  string.utf8.count <=
                    policy.maximumStringResponseBytes else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "string response is invalid or too large")
            }
            if let minimum = definition["minLength"]?.intValue,
               string.count < minimum {
                throw MCPElicitationBrokerError.invalidResponse(
                    "string response is shorter than minLength")
            }
            if let maximum = definition["maxLength"]?.intValue,
               string.count > maximum {
                throw MCPElicitationBrokerError.invalidResponse(
                    "string response is longer than maxLength")
            }
            if let pattern = definition["pattern"]?.stringValue {
                let expression = try NSRegularExpression(pattern: pattern)
                let range = NSRange(
                    string.startIndex..<string.endIndex,
                    in: string)
                guard expression.firstMatch(
                    in: string,
                    range: range)?.range == range else {
                    throw MCPElicitationBrokerError.invalidResponse(
                        "string response does not match pattern")
                }
            }
            try validateStringOption(string, definition: definition)
            if let format = definition["format"]?.stringValue,
               !validateFormat(string, format: format) {
                throw MCPElicitationBrokerError.invalidResponse(
                    "string response does not match format")
            }
        case "number":
            let number: Double
            if let double = value.doubleValue {
                number = double
            } else if let integer = value.intValue {
                number = Double(integer)
            } else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "number response has the wrong type")
            }
            try validateNumber(number, definition: definition)
        case "integer":
            guard let integer = value.intValue else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "integer response has the wrong type")
            }
            try validateNumber(Double(integer), definition: definition)
        case "boolean":
            guard value.boolValue != nil else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "boolean response has the wrong type")
            }
        case "array":
            guard let values = value.arrayValue,
                  values.count <= policy.maximumArrayItems else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "multi-select response is invalid or too large")
            }
            if let minimum = definition["minItems"]?.intValue,
               values.count < minimum {
                throw MCPElicitationBrokerError.invalidResponse(
                    "multi-select response has too few items")
            }
            if let maximum = definition["maxItems"]?.intValue,
               values.count > maximum {
                throw MCPElicitationBrokerError.invalidResponse(
                    "multi-select response has too many items")
            }
            guard case .object(let items)? = definition["items"] else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "multi-select item schema is unavailable")
            }
            for item in values {
                guard let string = item.stringValue else {
                    throw MCPElicitationBrokerError.invalidResponse(
                        "multi-select values must be strings")
                }
                try validateStringOption(string, definition: items)
            }
        default:
            throw MCPElicitationBrokerError.invalidResponse(
                "unsupported response type")
        }

        // A default is validated by the same rules but is server-supplied. No
        // special coercion is permitted.
        _ = validatingDefault
    }

    private static func validateStringOption(
        _ string: String,
        definition: [String: Value]
    ) throws {
        if let enumValue = definition["enum"],
           case .array(let values) = enumValue,
           !values.compactMap(\.stringValue).contains(string) {
            throw MCPElicitationBrokerError.invalidResponse(
                "response is not an allowed enum value")
        }
        let titled = definition["oneOf"] ?? definition["anyOf"]
        if let titled,
           case .array(let values) = titled {
            let allowed = values.compactMap { value -> String? in
                value.objectValue?["const"]?.stringValue
            }
            guard allowed.contains(string) else {
                throw MCPElicitationBrokerError.invalidResponse(
                    "response is not an allowed titled option")
            }
        }
    }

    private static func validateNumber(
        _ number: Double,
        definition: [String: Value]
    ) throws {
        let minimum = definition["minimum"]?.doubleValue
            ?? definition["minimum"]?.intValue.map(Double.init)
        let maximum = definition["maximum"]?.doubleValue
            ?? definition["maximum"]?.intValue.map(Double.init)
        if let minimum, number < minimum {
            throw MCPElicitationBrokerError.invalidResponse(
                "numeric response is below minimum")
        }
        if let maximum, number > maximum {
            throw MCPElicitationBrokerError.invalidResponse(
                "numeric response is above maximum")
        }
    }

    private static func validateFormat(
        _ string: String,
        format: String
    ) -> Bool {
        switch format {
        case "email":
            let parts = string.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2
                && !parts[0].isEmpty
                && parts[1].contains(".")
        case "uri":
            return URL(string: string)?.scheme != nil
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: string) != nil
        case "date-time":
            return ISO8601DateFormatter().date(from: string) != nil
        default:
            return false
        }
    }
}
