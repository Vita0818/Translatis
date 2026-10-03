import Foundation
import IntatisCore
import IntatisProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OpenAI wire DTOs (internal)

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let finish_reason: String?
    }
    struct UsageDTO: Decodable {
        struct PromptTokensDetailsDTO: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptTokensDetailsDTO?

        var usage: Usage {
            Usage(promptTokens: prompt_tokens,
                  cachedPromptTokens: prompt_tokens_details?.cached_tokens,
                  completionTokens: completion_tokens,
                  totalTokens: total_tokens)
        }
    }
    let choices: [Choice]?
    let usage: UsageDTO?
}

/// Internal typed signal used only to permit one same-route ordinary Chat
/// retry before any valid hosted-search payload has been accepted.
private struct HostedWebSearchUnsupportedError:
    Error, LocalizedError, Sendable
{
    var dialect: ChatHostedWebSearchDialect
    var signal: String
    var parameter: String?

    var errorDescription: String? {
        var message =
            "The selected provider rejected its hosted web-search request shape."
        if !signal.isEmpty {
            message += " Provider signal: \(signal)."
        }
        if let parameter, !parameter.isEmpty {
            message += " Parameter: \(parameter)."
        }
        return message
    }
}

// MARK: - Adapter

/// Maps Intatis chat requests onto the OpenAI-compatible `/chat/completions`
/// streaming wire. One conforming adapter for `WireFormat.openai`.
public struct OpenAIWireProvider: ChatProvider {
    // internal (not private) so the ToolCallingProvider conformance in
    // OpenAIToolCalling.swift can reuse endpoint/apiKey/http.
    let endpoint: ProviderEndpoint
    let apiKey: String
    let http: HTTPByteStreaming
    let runtimePolicy: ProviderRuntimePolicy
    public let toolCallingCapabilities:
        ToolCallingProviderCapabilities

    public init(endpoint: ProviderEndpoint,
                apiKey: String,
                http: HTTPByteStreaming,
                runtimePolicy: ProviderRuntimePolicy = .streaming,
                toolCallingCapabilities:
                    ToolCallingProviderCapabilities =
                        .chatCompletionsOnly) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
        self.toolCallingCapabilities =
            toolCallingCapabilities
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        if request.webSearch != nil {
            return streamResponsesChat(request)
        }
        return streamChatCompletions(request)
    }

    private func streamChatCompletions(
        _ request: ChatRequest
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request)
                    var attempt = 1
                    while true {
                        let parser = SSEParser()
                        var deliveredSemanticOutput = false
                        var sawCompletion = false
                        do {
                            for try await chunk in http.stream(urlRequest) {
                                for payload in parser.consume(chunk) {
                                    if try emit(
                                        payload,
                                        to: continuation,
                                        sawCompletion: &sawCompletion,
                                        deliveredSemanticOutput:
                                            &deliveredSemanticOutput
                                    ) {
                                        return
                                    }
                                }
                            }
                            for payload in parser.flush() {
                                if try emit(
                                    payload,
                                    to: continuation,
                                    sawCompletion: &sawCompletion,
                                    deliveredSemanticOutput:
                                        &deliveredSemanticOutput
                                ) {
                                    return
                                }
                            }
                            guard sawCompletion else {
                                continuation.finish(throwing: ProviderErrorFormatting.incompleteStream(
                                    operation: "streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if ProviderRuntime.shouldRetry(error: error,
                                                           attempt: attempt,
                                                           policy: runtimePolicy,
                                                           deliveredSemanticOutput: deliveredSemanticOutput) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting.retryHint(from: error))
                                continue
                            }
                            continuation.finish(throwing: ProviderRuntime.exhausted(
                                error,
                                attempts: attempt,
                                operation: "streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamResponsesChat(
        _ request: ChatRequest
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildResponsesChatRequest(request)
                    var attempt = 1

                    while true {
                        let parser = SSEParser()
                        var completed = false
                        var emittedText = ""
                        var citationOrder: [String] = []
                        var citationsByURL: [String: MessageCitation] = [:]
                        var acceptedResponsePayload = false
                        var deliveredSemanticOutput = false

                        func yieldMissingText(_ fullText: String) {
                            guard !fullText.isEmpty else { return }
                            if fullText.hasPrefix(emittedText) {
                                let suffix = String(fullText.dropFirst(emittedText.count))
                                if !suffix.isEmpty {
                                    emittedText += suffix
                                    deliveredSemanticOutput = true
                                    continuation.yield(.delta(suffix))
                                }
                            } else if emittedText.isEmpty {
                                emittedText = fullText
                                deliveredSemanticOutput = true
                                continuation.yield(.delta(fullText))
                            }
                        }

                        func recordCitation(_ citation: MessageCitation) {
                            if let existing = citationsByURL[citation.url] {
                                citationsByURL[citation.url] =
                                    Self.mergingResponsesChatCitation(
                                        existing,
                                        with: citation)
                            } else {
                                citationOrder.append(citation.url)
                                citationsByURL[citation.url] = citation
                            }
                        }

                        func recordMessageItem(_ item: [String: JSONValue]) {
                            yieldMissingText(Self.responsesChatMessageText(item))
                            for citation in Self.responsesChatCitations(item) {
                                recordCitation(citation)
                            }
                        }

                        func recordOutputItem(_ item: [String: JSONValue]) {
                            guard case .string(let itemType)? = item["type"] else {
                                return
                            }
                            switch itemType {
                            case "message":
                                recordMessageItem(item)
                            case "web_search_call":
                                for citation in Self.responsesChatSearchCallSources(item) {
                                    recordCitation(citation)
                                }
                            default:
                                break
                            }
                        }

                        func handle(_ payload: String) throws -> Bool {
                            if payload == "[DONE]" {
                                guard completed else {
                                    throw ProviderErrorFormatting.incompleteStream(
                                        operation: "Responses web-search streaming request")
                                }
                                continuation.finish()
                                return true
                            }
                            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty,
                                  let data = trimmed.data(using: .utf8) else {
                                return false
                            }
                            if let unsupported =
                                Self.hostedWebSearchUnsupported(
                                    from: data,
                                    dialect: Self.webSearchDialect(request)) {
                                throw unsupported
                            }
                            if let providerError = ProviderErrorFormatting.streamErrorPayload(data) {
                                throw providerError
                            }
                            let value: JSONValue
                            do {
                                value = try JSONDecoder().decode(JSONValue.self, from: data)
                            } catch {
                                throw ProviderErrorFormatting.invalidStreamPayload(
                                    trimmed,
                                    underlying: error)
                            }
                            guard case .object(let event) = value,
                                  case .string(let eventType)? = event["type"] else {
                                throw IntatisError.decoding(
                                    "Responses stream event is missing its type.")
                            }
                            // A status-only event proves that hosted search was
                            // accepted, so an unsupported-tool error must not
                            // fall back to ordinary Chat. It has not delivered
                            // semantic output, so a transient transport failure
                            // may still reconnect through the separate fence.
                            acceptedResponsePayload = true

                            switch eventType {
                            case "response.output_text.delta":
                                if case .string(let delta)? = event["delta"],
                                   !delta.isEmpty {
                                    emittedText += delta
                                    deliveredSemanticOutput = true
                                    continuation.yield(.delta(delta))
                                }

                            case "response.output_text.done":
                                if case .string(let text)? = event["text"] {
                                    yieldMissingText(text)
                                }

                            case "response.output_text.annotation.added":
                                if case .object(let annotation)? = event["annotation"],
                                   let citation = Self.responsesChatCitation(annotation) {
                                    recordCitation(citation)
                                }

                            case "response.output_item.done":
                                guard case .object(let item)? = event["item"],
                                      case .string(_)? = item["type"] else {
                                    throw IntatisError.decoding(
                                        "Responses output_item.done is missing a typed item.")
                                }
                                recordOutputItem(item)

                            case "response.completed":
                                guard case .object(let response)? = event["response"],
                                      case .string(let responseID)? = response["id"],
                                      !responseID.isEmpty else {
                                    throw IntatisError.decoding(
                                        "Responses completion is missing its response ID.")
                                }
                                if case .array(let output)? = response["output"] {
                                    for value in output {
                                        guard case .object(let item) = value else {
                                            continue
                                        }
                                        recordOutputItem(item)
                                    }
                                }
                                for url in citationOrder {
                                    if let citation = citationsByURL[url] {
                                        deliveredSemanticOutput = true
                                        continuation.yield(.citation(citation))
                                    }
                                }
                                if let usage = Self.responsesChatUsage(response) {
                                    deliveredSemanticOutput = true
                                    continuation.yield(.usage(usage))
                                }
                                deliveredSemanticOutput = true
                                continuation.yield(.done)
                                completed = true
                                continuation.finish()
                                return true

                            case "response.failed":
                                if let contextWindow = ProviderErrorFormatting.contextWindowExceeded(
                                    from: .object(event),
                                    operation: "Responses web-search request") {
                                    throw contextWindow
                                }
                                throw IntatisError.provider(
                                    "Responses web-search request failed. \(Self.responsesChatFailureMessage(event))")

                            case "response.incomplete":
                                throw IntatisError.decoding(
                                    "Responses web-search request was incomplete: \(Self.responsesChatIncompleteReason(event)).")

                            default:
                                break
                            }
                            return false
                        }

                        do {
                            for try await chunk in http.stream(urlRequest) {
                                for payload in parser.consume(chunk) {
                                    if try handle(payload) { return }
                                }
                            }
                            for payload in parser.flush() {
                                if try handle(payload) { return }
                            }
                            guard completed else {
                                continuation.finish(throwing: ProviderErrorFormatting.incompleteStream(
                                    operation: "Responses web-search streaming request"))
                                return
                            }
                            continuation.finish()
                            return
                        } catch {
                            if !acceptedResponsePayload,
                               let webSearch = request.webSearch,
                               webSearch.unsupportedBehavior
                                   == .retryOrdinaryChat,
                               Self.isHostedWebSearchUnsupported(
                                   error,
                                   dialect: webSearch.dialect) {
                                try Task.checkCancellation()
                                var ordinaryRequest = request
                                ordinaryRequest.webSearch = nil
                                for try await chunk in
                                    streamChatCompletions(ordinaryRequest) {
                                    continuation.yield(chunk)
                                }
                                continuation.finish()
                                return
                            }
                            if ProviderRuntime.shouldRetry(
                                error: error,
                                attempt: attempt,
                                policy: runtimePolicy,
                                deliveredSemanticOutput: deliveredSemanticOutput) {
                                attempt += 1
                                try await ProviderRuntime.sleepBeforeRetry(
                                    nextAttempt: attempt,
                                    policy: runtimePolicy,
                                    retryHint: ProviderErrorFormatting.retryHint(from: error))
                                continue
                            }
                            continuation.finish(throwing: ProviderRuntime.exhausted(
                                error,
                                attempts: attempt,
                                operation: "Responses web-search streaming request"))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: ProviderErrorFormatting.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func webSearchDialect(
        _ request: ChatRequest
    ) -> ChatHostedWebSearchDialect {
        // `streamResponsesChat` is reached only when this configuration exists;
        // keep the helper total so the nested parser does not need to unwrap it.
        request.webSearch?.dialect ?? .openAIResponses
    }

    private static func isHostedWebSearchUnsupported(
        _ error: Error,
        dialect: ChatHostedWebSearchDialect
    ) -> Bool {
        if let unsupported = error as? HostedWebSearchUnsupportedError {
            return unsupported.dialect == dialect
        }
        guard let status = error as? ProviderHTTPStatusError else {
            return false
        }
        return hostedWebSearchUnsupported(
            from: status.body,
            dialect: dialect,
            statusCode: status.statusCode) != nil
    }

    /// Classifies only structured provider codes plus structural parameter
    /// fields. Free text and a bare HTTP status are deliberately insufficient.
    private static func hostedWebSearchUnsupported(
        from data: Data,
        dialect: ChatHostedWebSearchDialect,
        statusCode: Int? = nil
    ) -> HostedWebSearchUnsupportedError? {
        if let statusCode,
           statusCode != 400,
           statusCode != 404,
           statusCode != 422 {
            return nil
        }
        guard let value = try? JSONDecoder().decode(
            JSONValue.self,
            from: data),
              case .object(let root) = value else {
            return nil
        }

        let errorObject: [String: JSONValue]
        if case .object(let nested)? = root["error"] {
            errorObject = nested
        } else if case .object(let response)? = root["response"],
                  case .object(let nested)? = response["error"] {
            errorObject = nested
        } else {
            errorObject = root
        }

        func string(_ key: String) -> String? {
            guard case .string(let value)? = errorObject[key] else {
                return nil
            }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let rawSignal = string("code") ?? string("type")
        guard let rawSignal else { return nil }
        let signal = rawSignal.lowercased()
        let directSignals: Set<String> = [
            "web_search_not_supported",
            "web_search_unsupported",
            "unsupported_web_search",
        ]
        let parameterSignals: Set<String> = [
            "unsupported_parameter",
            "unknown_parameter",
            "unsupported_value",
        ]
        let parameter = string("param") ?? string("parameter")
        let normalizedParameter = parameter?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let isSearchParameter = normalizedParameter.map {
            $0 == "tool_choice"
                || $0 == "tools"
                || $0.hasPrefix("tools[")
                || $0.hasPrefix("tools.")
        } ?? false

        guard directSignals.contains(signal)
            || (parameterSignals.contains(signal) && isSearchParameter) else {
            return nil
        }
        return HostedWebSearchUnsupportedError(
            dialect: dialect,
            signal: rawSignal,
            parameter: parameter)
    }

    /// Returns true if the stream is finished (saw `[DONE]`).
    private func emit(_ payload: String,
                      to continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation,
                      sawCompletion: inout Bool,
                      deliveredSemanticOutput: inout Bool) throws -> Bool {
        if payload == "[DONE]" {
            if !sawCompletion {
                deliveredSemanticOutput = true
                continuation.yield(.done)
                sawCompletion = true
            }
            continuation.finish()
            return true
        }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return false
        }
        if let providerError = ProviderErrorFormatting.streamErrorPayload(data) {
            throw providerError
        }
        let chunk: OpenAIStreamChunk
        do {
            chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        } catch {
            throw ProviderErrorFormatting.invalidStreamPayload(trimmed, underlying: error)
        }
        if let choices = chunk.choices {
            for choice in choices {
                if let content = choice.delta?.content, !content.isEmpty {
                    deliveredSemanticOutput = true
                    continuation.yield(.delta(content))
                }
            }
            if choices.contains(where: { $0.finish_reason != nil }), !sawCompletion {
                deliveredSemanticOutput = true
                continuation.yield(.done)
                sawCompletion = true
            }
        }
        if let u = chunk.usage {
            deliveredSemanticOutput = true
            continuation.yield(.usage(u.usage))
        }
        return false
    }

    func buildRequest(_ request: ChatRequest) throws -> URLRequest {
        if request.webSearch != nil {
            return try buildResponsesChatRequest(request)
        }
        return try buildChatCompletionsRequest(request)
    }

    private func buildChatCompletionsRequest(
        _ request: ChatRequest
    ) throws -> URLRequest {
        var r = URLRequest(url: try endpoint.validatedChatCompletionsURL(operation: "streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        let requestAdapter =
            endpoint.requestAdapter(for: request.model)
        var root = try Self.configuredRequestBody(
            endpoint: endpoint,
            model: request.model)
        root["model"] = .string(request.model.rawValue)
        root["messages"] = .array(request.messages.map(Self.chatMessageJSON))
        root["stream"] = .bool(true)
        try Self.applyChatCompletionsInvocationControls(
            to: &root,
            requestAdapter: requestAdapter)
        if let t = request.temperature { root["temperature"] = .number(t) }
        Self.applyChatCompletionsReasoningOptions(
            to: &root,
            runtimeEffort: request.reasoningEffort,
            requestAdapter: requestAdapter)
        if request.includeUsage { root["stream_options"] = .object(["include_usage": .bool(true)]) }
        r.httpBody = try Self.encodeRequestBody(root)
        return r
    }

    private func buildResponsesChatRequest(
        _ request: ChatRequest
    ) throws -> URLRequest {
        guard let webSearch = request.webSearch else {
            throw IntatisError.config(
                "Responses web-search request is missing its search configuration.")
        }
        var root = try Self.configuredRequestBody(
            endpoint: endpoint,
            model: request.model)
        let instructions = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let input = request.messages.compactMap(Self.responsesChatInputJSON)

        root["model"] = .string(request.model.rawValue)
        if instructions.isEmpty {
            root.removeValue(forKey: "instructions")
        } else {
            root["instructions"] = .string(instructions)
        }
        root["input"] = .array(input)
        root["stream"] = .bool(true)
        root["store"] = .bool(false)
        root["tools"] = .array([
            Self.hostedWebSearchToolJSON(webSearch),
        ])
        // Transparent Chat uses `auto`; an explicit agent search tool uses
        // `required` so a successful tool result cannot be an ordinary model
        // answer that silently skipped the hosted search.
        root["tool_choice"] = .string(
            webSearch.toolChoice.rawValue)
        root.removeValue(forKey: "messages")
        root.removeValue(forKey: "n")
        root.removeValue(forKey: "parallel_tool_calls")
        root.removeValue(forKey: "stream_options")
        if let temperature = request.temperature {
            root["temperature"] = .number(temperature)
        }
        Self.applyResponsesReasoningOptions(
            to: &root,
            runtimeEffort: request.reasoningEffort)

        var urlRequest = URLRequest(
            url: try endpoint.validatedResponsesURL(
                operation: "Responses web-search streaming request"))
        ProviderRuntime.apply(runtimePolicy, to: &urlRequest)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(
            ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
            forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.encodeRequestBody(root)
        return urlRequest
    }

    private static func hostedWebSearchToolJSON(
        _ configuration: ChatWebSearchConfiguration
    ) -> JSONValue {
        switch configuration.dialect {
        case .openAIResponses:
            return .object([
                "type": .string("web_search"),
                "search_context_size":
                    .string(configuration.contextSize.rawValue),
            ])

        case .openRouterServerTool:
            return .object([
                "type": .string("openrouter:web_search"),
                "parameters": .object([
                    "search_context_size":
                        .string(configuration.contextSize.rawValue),
                ]),
            ])
        }
    }

    private static func responsesChatInputJSON(
        _ message: ChatMessage
    ) -> JSONValue? {
        guard message.role != .system,
              let role = AgentRole(rawValue: message.role.rawValue) else {
            return nil
        }
        return responsesInputJSON(.message(
            role: role,
            content: message.content,
            images: message.images))
    }

    private static func responsesChatMessageText(
        _ item: [String: JSONValue]
    ) -> String {
        guard case .array(let content)? = item["content"] else {
            return ""
        }
        return content.compactMap { part -> String? in
            guard case .object(let object) = part,
                  case .string("output_text")? = object["type"],
                  case .string(let text)? = object["text"] else {
                return nil
            }
            return text
        }.joined()
    }

    private static func responsesChatCitations(
        _ item: [String: JSONValue]
    ) -> [MessageCitation] {
        guard case .array(let content)? = item["content"] else {
            return []
        }
        var citations: [MessageCitation] = []
        for part in content {
            guard case .object(let object) = part,
                  case .array(let annotations)? = object["annotations"] else {
                continue
            }
            for annotation in annotations {
                guard case .object(let value) = annotation,
                      let citation = responsesChatCitation(value) else {
                    continue
                }
                citations.append(citation)
            }
        }
        return citations
    }

    private static func responsesChatSearchCallSources(
        _ item: [String: JSONValue]
    ) -> [MessageCitation] {
        guard case .string("web_search_call")? = item["type"],
              case .object(let action)? = item["action"] else {
            return []
        }
        var rawURLs: [String] = []
        if case .array(let sources)? = action["sources"] {
            for source in sources {
                guard case .object(let value) = source,
                      case .string("url")? = value["type"],
                      case .string(let rawURL)? = value["url"] else {
                    continue
                }
                rawURLs.append(rawURL)
            }
        }
        if case .string(let actionType)? = action["type"],
           actionType == "open_page" || actionType == "find_in_page",
           case .string(let rawURL)? = action["url"] {
            rawURLs.append(rawURL)
        }
        return rawURLs.compactMap { rawURL in
            responsesChatCitation([
                "type": .string("url_citation"),
                "url": .string(rawURL),
            ])
        }
    }

    private static func responsesChatCitation(
        _ annotation: [String: JSONValue]
    ) -> MessageCitation? {
        guard case .string("url_citation")? = annotation["type"] else {
            return nil
        }
        let citation: [String: JSONValue]
        if case .object(let nested)? = annotation["url_citation"] {
            citation = nested
        } else {
            citation = annotation
        }
        func field(_ key: String) -> JSONValue? {
            citation[key] ?? annotation[key]
        }
        guard case .string(let rawURL)? = field("url"),
              rawURL.count <= 4_096,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        let rawTitle: String
        if case .string(let value)? = field("title") {
            rawTitle = value
        } else {
            rawTitle = ""
        }
        let compactTitle = rawTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = compactTitle.isEmpty
            ? host
            : String(compactTitle.prefix(200))
        let content: String?
        if case .string(let value)? = field("content"),
           !value.isEmpty {
            content = value
        } else {
            content = nil
        }
        return MessageCitation(
            url: url.absoluteString,
            title: title,
            content: content,
            startIndex: responsesChatCitationIndex(field("start_index")),
            endIndex: responsesChatCitationIndex(field("end_index")))
    }

    private static func responsesChatCitationIndex(
        _ value: JSONValue?
    ) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 0,
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    private static func mergingResponsesChatCitation(
        _ current: MessageCitation,
        with update: MessageCitation
    ) -> MessageCitation {
        let title = responsesChatPreferredCitationTitle(
            current,
            update: update)
        let content: String?
        switch (current.content, update.content) {
        case let (existing?, candidate?) where candidate.count > existing.count:
            content = candidate
        case let (existing?, _):
            content = existing
        case (nil, let candidate?):
            content = candidate
        case (nil, nil):
            content = nil
        }
        return MessageCitation(
            url: current.url,
            title: title,
            content: content,
            startIndex: update.startIndex ?? current.startIndex,
            endIndex: update.endIndex ?? current.endIndex)
    }

    private static func responsesChatPreferredCitationTitle(
        _ current: MessageCitation,
        update: MessageCitation
    ) -> String {
        let host = URL(string: current.url)?.host
        let currentIsFallback = current.title == host
        let updateIsFallback = update.title == host
        if currentIsFallback, !updateIsFallback {
            return update.title
        }
        if !currentIsFallback, updateIsFallback {
            return current.title
        }
        return update.title.count > current.title.count
            ? update.title
            : current.title
    }

    private static func responsesChatUsage(
        _ response: [String: JSONValue]
    ) -> Usage? {
        guard case .object(let usage)? = response["usage"] else {
            return nil
        }
        func integer(_ key: String) -> Int? {
            guard case .number(let value)? = usage[key],
                  value.isFinite else {
                return nil
            }
            return Int(value)
        }
        var cachedTokens: Int?
        if case .object(let details)? = usage["input_tokens_details"],
           case .number(let value)? = details["cached_tokens"],
           value.isFinite {
            cachedTokens = Int(value)
        }
        return Usage(
            promptTokens: integer("input_tokens"),
            cachedPromptTokens: cachedTokens,
            completionTokens: integer("output_tokens"),
            totalTokens: integer("total_tokens"))
    }

    private static func responsesChatFailureMessage(
        _ event: [String: JSONValue]
    ) -> String {
        guard case .object(let response)? = event["response"],
              case .object(let error)? = response["error"],
              case .string(let message)? = error["message"],
              !message.isEmpty else {
            return "The provider did not include an error message."
        }
        return PermissionReviewTextSanitizer.sanitizeDiagnostic(
            message,
            maxCharacters: 360).text
    }

    private static func responsesChatIncompleteReason(
        _ event: [String: JSONValue]
    ) -> String {
        guard case .object(let response)? = event["response"],
              case .object(let details)? = response["incomplete_details"],
              case .string(let reason)? = details["reason"],
              !reason.isEmpty else {
            return "unknown"
        }
        return PermissionReviewTextSanitizer.sanitizeDiagnostic(
            reason,
            maxCharacters: 160).text
    }

    /// Model options are an open JSON extension point. Intatis protects only
    /// the structural fields that must match the actual runtime request.
    /// Unknown keys remain verbatim. Known provider SDK options are lowered by
    /// the exact package adapter frozen for the selected model.
    static func configuredRequestBody(endpoint: ProviderEndpoint,
                                      model: ModelID)
        throws -> [String: JSONValue]
    {
        var body = endpoint.requestOptions(for: model)
        for key in [
            "model", "messages", "tools", "stream",
            "stream_options",
            "n", "best_of", "num_return_sequences", "candidate_count",
        ] {
            body.removeValue(forKey: key)
        }
        try applyConfiguredChatCompletionsOptions(
            to: &body,
            requestAdapter:
                endpoint.requestAdapter(for: model))
        return body
    }

    /// Applies only controls that the selected package adapter would synthesize
    /// for this invocation. The pinned OpenCode adapters do not send `n`, and
    /// neither turns parallel-safe tool metadata into `parallel_tool_calls`.
    /// Historical Intatis endpoints retain their previous wire behavior.
    static func applyChatCompletionsInvocationControls(
        to body: inout [String: JSONValue],
        requestAdapter: ProviderRequestAdapter,
        parallelToolCalls: Bool? = nil
    ) throws {
        switch try requestAdapter
            .chatCompletionsAdapter()
        {
        case .legacyOpenAIWire:
            body["n"] = .number(1)
            if let parallelToolCalls {
                body["parallel_tool_calls"] =
                    .bool(parallelToolCalls)
            }

        case .openAICompatible,
             .openRouter:
            // @ai-sdk/openai-compatible@2.0.41 omits both fields.
            // @openrouter/ai-sdk-provider@2.9.0 also omits `n` and
            // emits parallel_tool_calls only from explicit model settings,
            // not from call-level tool metadata. Any explicitly configured
            // wire option has already been lowered into `body` above.
            return
        }
    }

    /// Mirrors the package-specific option boundary used by OpenCode. The
    /// configuration remains untouched; only this request-owned body is
    /// lowered. This is deliberately not a global camel/snake normalizer.
    private static func applyConfiguredChatCompletionsOptions(
        to body: inout [String: JSONValue],
        requestAdapter: ProviderRequestAdapter
    ) throws {
        switch try requestAdapter
            .chatCompletionsAdapter()
        {
        case .legacyOpenAIWire:
            return

        case .openAICompatible:
            // @ai-sdk/openai-compatible@2.0.41 treats these camelCase names as
            // SDK options. The explicit wire properties are written after its
            // unknown-option spread, so an absent camelCase value also removes
            // a same-named raw-wire alias from the final JSON.
            let reasoningEffort =
                body.removeValue(
                    forKey: "reasoningEffort")
            body.removeValue(
                forKey: "reasoning_effort")
            if let reasoningEffort {
                guard case .string = reasoningEffort else {
                    throw IntatisError.config(
                        "reasoningEffort must be a string for the selected provider adapter")
                }
                body["reasoning_effort"] =
                    reasoningEffort
            }

            let textVerbosity =
                body.removeValue(
                    forKey: "textVerbosity")
            body.removeValue(forKey: "verbosity")
            if let textVerbosity {
                guard case .string = textVerbosity else {
                    throw IntatisError.config(
                        "textVerbosity must be a string for the selected provider adapter")
                }
                body["verbosity"] = textVerbosity
            }

            if let strictJSONSchema =
                body.removeValue(
                    forKey: "strictJsonSchema") {
                guard case .bool = strictJSONSchema else {
                    throw IntatisError.config(
                        "strictJsonSchema must be a boolean for the selected provider adapter")
                }
                // This option controls SDK-side response-format construction;
                // it is never itself a wire field.
            }

            if let user = body["user"],
               case .string = user {
                // Recognized by the SDK and emitted with the same wire name.
            } else if body["user"] != nil {
                throw IntatisError.config(
                    "user must be a string for the selected provider adapter")
            }

        case .openRouter:
            // The OpenRouter SDK spreads provider options without translating
            // reasoningEffort. Its one compatibility alias in this boundary is
            // cacheControl -> cache_control.
            if let cacheControl =
                body.removeValue(
                    forKey: "cacheControl"),
               cacheControl != .null,
               body["cache_control"] == nil {
                body["cache_control"] =
                    cacheControl
            }
        }
    }

    /// Runtime reasoning remains host-owned, but its wire shape is chosen by
    /// the frozen package adapter instead of by endpoint-name heuristics.
    static func applyChatCompletionsReasoningOptions(
        to body: inout [String: JSONValue],
        runtimeEffort: ReasoningEffort?,
        requestAdapter: ProviderRequestAdapter
    ) {
        guard let runtimeEffort else {
            return
        }
        switch try? requestAdapter
            .chatCompletionsAdapter()
        {
        case .openRouter:
            var reasoning: [String: JSONValue] = [:]
            if case .object(let configured)? =
                body["reasoning"] {
                reasoning = configured
            }
            reasoning["effort"] =
                .string(runtimeEffort.rawValue)
            body["reasoning"] = .object(reasoning)

        case .legacyOpenAIWire,
             .openAICompatible:
            body["reasoning_effort"] =
                .string(runtimeEffort.rawValue)

        case nil:
            // Unsupported adapters were rejected while lowering configured
            // options, before this host overlay is reached.
            return
        }
    }

    /// Responses uses the nested `reasoning.effort` shape. Normalize both the
    /// Chat Completions shorthand and the SDK-only camelCase alias at this wire
    /// boundary while preserving unrelated nested reasoning options.
    static func applyResponsesReasoningOptions(
        to body: inout [String: JSONValue],
        runtimeEffort: ReasoningEffort?
    ) {
        let sdkAlias =
            body.removeValue(forKey: "reasoningEffort")
        let chatCompletionsAlias =
            body.removeValue(forKey: "reasoning_effort")

        if let runtimeEffort {
            var reasoning: [String: JSONValue] = [:]
            if case .object(let configured)? =
                body["reasoning"] {
                reasoning = configured
            }
            reasoning["effort"] =
                .string(runtimeEffort.rawValue)
            body["reasoning"] = .object(reasoning)
            return
        }

        let compatibleEffort =
            chatCompletionsAlias ?? sdkAlias
        guard let compatibleEffort else { return }

        if case .object(var reasoning)? =
            body["reasoning"] {
            if reasoning["effort"] == nil {
                reasoning["effort"] = compatibleEffort
                body["reasoning"] = .object(reasoning)
            }
        } else if body["reasoning"] == nil {
            body["reasoning"] = .object([
                "effort": compatibleEffort,
            ])
        }
    }

    /// Provider request bodies are compared, cached, and audited as bytes in
    /// addition to being interpreted as JSON. Sorting every keyed container
    /// makes equivalent request bodies deterministic without narrowing the
    /// open provider-options extension point.
    static func encodeRequestBody(
        _ body: [String: JSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(body))
    }

    /// Encodes a message as a plain string, or as a content-parts array when it
    /// carries images (OpenAI vision format).
    static func chatMessageJSON(_ m: ChatMessage) -> JSONValue {
        if m.images.isEmpty {
            return .object(["role": .string(m.role.rawValue), "content": .string(m.content)])
        }
        var parts: [JSONValue] = []
        if !m.content.isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(m.content)]))
        }
        for image in m.images {
            parts.append(.object(["type": .string("image_url"),
                                  "image_url": .object(["url": .string(image.url)])]))
        }
        return .object(["role": .string(m.role.rawValue), "content": .array(parts)])
    }
}

// MARK: - Real transport (Apple platforms)

/// URLSession-backed byte streaming. Used at runtime on macOS; on Linux (where
/// `URLSession.bytes(for:)` is unavailable) it reports unsupported — tests never
/// hit it because they inject a fake `HTTPByteStreaming`.
public struct URLSessionStreamingClient: HTTPByteStreaming {
    public init() {}

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(Darwin)
                do {
                    let (bytes, response) = try await ProviderURLSession.noRedirect.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let body = try await ProviderErrorFormatting.cappedBody(from: bytes)
                        continuation.finish(throwing: ProviderHTTPStatusError(
                            statusCode: http.statusCode,
                            body: body,
                            headers: HTTPDataResponse.headers(from: http),
                            operation: "streaming request"))
                        return
                    }
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: IntatisError.provider("Streaming HTTP is unavailable on this platform"))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
